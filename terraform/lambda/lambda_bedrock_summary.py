import json
import os
import urllib.parse

import boto3
from botocore.exceptions import ClientError

s3_client = boto3.client("s3")
OBS_DEBUG = os.environ.get("OBSERVABILITY_DEBUG", "0") == "1"
OBS_TRACE = os.environ.get("OBSERVABILITY_TRACE", "0") == "1"

bedrock_client = boto3.client(
    "bedrock-runtime",
    region_name=os.environ.get("BEDROCK_REGION", "us-east-2"),
)

OUTPUT_BUCKET = os.environ.get("SUMMARY_OUTPUT_BUCKET", "")
OUTPUT_PREFIX = os.environ.get("SUMMARY_OUTPUT_PREFIX", "model/resumo/")
MODEL_PREFIX = os.environ.get("MODEL_PREFIX", "model/")
MODEL_ID = os.environ.get("BEDROCK_MODEL_ID", "amazon.nova-lite-v1:0")
# Para modelos que requerem inference profile (como deepseek.r1-v1:0), use o profile ID
# Trata string vazia como None (quando não há inference profile necessário)
inference_profile_raw = os.environ.get("BEDROCK_INFERENCE_PROFILE", None)
INFERENCE_PROFILE = inference_profile_raw if inference_profile_raw and inference_profile_raw.strip() else None

# Nome do arquivo do prompt padrão (empacotado junto com a Lambda; origem: prompt/guardrails.md)
DEFAULT_PROMPT_FILENAME = "guardrails.md"


def _log(msg: str, always: bool = False):
    """Log controlado por feature flags. always=True ignora flags."""
    if always or OBS_TRACE or OBS_DEBUG:
        print(msg)


def _load_default_system_prompt() -> str:
    """Carrega o prompt padrão do arquivo guardrails.md empacotado na Lambda."""
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), DEFAULT_PROMPT_FILENAME)
    try:
        with open(path, "r", encoding="utf-8") as f:
            text = f.read().strip()
        if text:
            _log(f"Prompt padrão carregado de {DEFAULT_PROMPT_FILENAME} ({len(text)} caracteres)")
            return text
    except OSError as e:
        _log(f"Arquivo guardrails.md não encontrado ou erro ao ler: {e}", always=True)
    return (
        "Você é um assistente especializado em resumir conteúdos de palestras, "
        "aulas e vídeos técnicos. Gere um resumo detalhado em português, em formato "
        "Markdown, com seções, tópicos, bullets e subtítulos.\n\n"
        "Use tabelas Markdown quando fizer sentido (ex.: comparações, listas com atributos).\n\n"
        "Regras:\n"
        "- Não invente conteúdo que não esteja na transcrição.\n"
        "- Mantenha o foco nas ideias principais, exemplos importantes e conclusões.\n"
        "- Se houver passos práticos, destaque-os em listas numeradas."
    )


def extract_plain_text_from_srt(srt_str: str) -> str:
    """
    Remove numeração, timestamps e cabeçalho do modelo do SRT,
    retornando apenas o texto das legendas.
    """
    lines = srt_str.splitlines()
    content_lines = []

    for line in lines:
        stripped = line.strip()

        # pula linhas vazias
        if not stripped:
            continue

        # pula cabeçalho do modelo LLM (inserido pela Lambda)
        if stripped.startswith("# Modelo LLM:"):
            continue

        # pula linhas só com número (1, 2, 3...)
        if stripped.isdigit():
            continue

        # pula linhas com timestamp --> 
        # Ex: 00:00:01,000 --> 00:00:03,000
        if "-->" in stripped:
            continue

        # resto é texto da legenda
        content_lines.append(stripped)

    # junta tudo em parágrafos
    return "\n".join(content_lines)


def extract_video_base_name(srt_filename: str) -> str:
    """
    Extrai o nome base do vídeo a partir do nome do arquivo .srt.
    O Transcribe gera arquivos como: meetup-{nome}-{timestamp}.srt
    Precisamos extrair apenas o {nome} para encontrar o prompt.
    """
    # Remove a extensão .srt
    name_without_ext = srt_filename.rsplit(".", 1)[0]
    
    # Remove o prefixo "meetup-" se existir
    if name_without_ext.startswith("meetup-"):
        name_without_ext = name_without_ext[7:]  # Remove "meetup-"
    
    # Remove o timestamp (últimos números após o último hífen)
    # Ex: "palla-1763239925" -> "palla"
    parts = name_without_ext.split("-")
    # Se a última parte é numérica (timestamp), remove
    if len(parts) > 1 and parts[-1].isdigit():
        return "-".join(parts[:-1])
    
    return name_without_ext


def get_system_prompt(base_name: str, bucket: str) -> str:
    """
    Monta o system prompt combinando:
    - guardrails.md: guardrails (regras gerais), sempre aplicados.
    - prompts/{base_name}.txt no S3: prompt personalizado do usuário, quando existir.
    Quando ambos existem, os dois são enviados em conjunto (guardrails + instruções específicas).
    """
    guardrails = _load_default_system_prompt()

    prompt_key = f"{MODEL_PREFIX}prompts/{base_name}.txt"
    try:
        _log(f"Tentando ler prompt personalizado de s3://{bucket}/{prompt_key}")
        response = s3_client.get_object(Bucket=bucket, Key=prompt_key)
        custom_text = response["Body"].read().decode("utf-8", errors="ignore").strip()
        if custom_text:
            _log(f"Prompt personalizado encontrado ({len(custom_text)} caracteres). Usando guardrails + prompt personalizado.")
            return _combine_prompts(guardrails, custom_text)
    except ClientError as e:
        error_code = e.response.get("Error", {}).get("Code", "")
        if error_code == "NoSuchKey":
            _log(f"Prompt personalizado não encontrado em {prompt_key}, usando apenas guardrails (guardrails.md)")
        elif error_code == "AccessDenied":
            _log(f"Sem permissão para ler {prompt_key}, usando apenas guardrails (guardrails.md)", always=True)
        else:
            _log(f"Erro ao ler prompt personalizado: {e}, usando apenas guardrails (guardrails.md)", always=True)

    return guardrails


def _combine_prompts(guardrails: str, custom_prompt: str) -> str:
    """Combina guardrails (guardrails.md) com o prompt personalizado em um único system prompt."""
    return (
        f"{guardrails}\n\n"
        "---\n"
        "Instruções específicas para este vídeo (prompt personalizado):\n\n"
        f"{custom_prompt}"
    )


def get_selected_model(base_name: str, bucket: str) -> str:
    """
    Tenta ler o modelo selecionado do S3.
    Se não encontrar, retorna o modelo padrão da variável de ambiente.
    """
    model_key = f"{MODEL_PREFIX}models/{base_name}.txt"
    
    try:
        _log(f"Tentando ler modelo selecionado de s3://{bucket}/{model_key}")
        response = s3_client.get_object(Bucket=bucket, Key=model_key)
        model_id = response["Body"].read().decode("utf-8", errors="ignore").strip()
        _log(f"Modelo selecionado encontrado: {model_id}")
        return model_id
    except ClientError as e:
        error_code = e.response.get("Error", {}).get("Code", "")
        if error_code == "NoSuchKey":
            _log(f"Modelo selecionado não encontrado em {model_key}, usando modelo padrão: {MODEL_ID}")
        elif error_code == "AccessDenied":
            _log(f"Sem permissão para ler {model_key}, usando modelo padrão: {MODEL_ID}", always=True)
        else:
            _log(f"Erro ao ler modelo selecionado: {e}, usando modelo padrão: {MODEL_ID}", always=True)
    
    return MODEL_ID


def get_inference_profile_for_model(model_id: str):
    """
    Retorna o inference profile apropriado para o modelo.
    Alguns modelos (Nova, DeepSeek) exigem inference profile em vez de on-demand.
    """
    profiles = {
        "deepseek.r1-v1:0": "us.deepseek.r1-v1:0",
        "amazon.nova-2-lite-v1:0": "us.amazon.nova-2-lite-v1:0",
    }
    return profiles.get(model_id)


def call_bedrock_nova(transcript_text: str, system_prompt: str, model_id: str, inference_profile: str = None) -> str:
    """
    Chama o Amazon Bedrock para gerar
    um resumo detalhado em Markdown.
    """
    user_message = (
        "Abaixo está a transcrição (já limpa) de um vídeo. "
        "Gere um resumo detalhado em Markdown, conforme as regras.\n\n"
        "IMPORTANTE: Entregue o resumo em Markdown puro, sem envolver em blocos de código (```). "
        "O conteúdo será renderizado diretamente - use tabelas, listas e cabeçalhos normalmente.\n\n"
        "=== TRANSCRIÇÃO INÍCIO ===\n"
        f"{transcript_text}\n"
        "=== TRANSCRIÇÃO FIM ==="
    )

    try:
        # Se houver inference profile configurado, use-o como modelId
        # A API converse aceita inference profile ID como modelId
        # Caso contrário, use o model_id diretamente
        model_id_to_use = inference_profile if inference_profile else model_id
        
        _log(f"Usando modelo: {model_id_to_use} (model_id={model_id}, inference_profile={inference_profile})")
        
        response = bedrock_client.converse(
            modelId=model_id_to_use,
            system=[{"text": system_prompt}],
            messages=[
                {
                    "role": "user",
                    "content": [{"text": user_message}],
                }
            ],
            inferenceConfig={
                "maxTokens": 2048,
                "temperature": 0.3,
                "topP": 0.9,
            },
        )

        content_blocks = response["output"]["message"]["content"]
        # pego o primeiro bloco de texto
        for block in content_blocks:
            if "text" in block:
                return block["text"]

        raise RuntimeError("Resposta do modelo não contém texto.")
    except ClientError as e:
        _log(f"Erro ao chamar Bedrock: {e}", always=True)
        raise


def lambda_handler(event, context):
    # Log incondicional no início - garante que invocações apareçam no CloudWatch
    detail = event.get("detail", {})
    bucket = detail.get("bucket", {}).get("name", "?")
    key = detail.get("object", {}).get("key", "?")
    print(f"[INVOKE] Lambda acionada: bucket={bucket} key={key}")

    if OBS_DEBUG:
        print(f"[DEBUG] Evento recebido: {json.dumps(event, default=str)}")
    elif OBS_TRACE:
        print(f"[TRACE] Evento: bucket={bucket} key={key}")

    detail = event.get("detail", {})
    bucket = detail.get("bucket", {}).get("name")
    obj = detail.get("object", {})
    key = obj.get("key")

    if not bucket or not key:
        _log("Evento sem bucket ou key. Nada a fazer.", always=True)
        return {"status": "ignored"}

    key = urllib.parse.unquote_plus(key)

    # Só processa arquivos .srt
    if not key.lower().endswith(".srt"):
        _log(f"Ignorando objeto {key}, não é .srt.", always=True)
        return {"status": "ignored", "key": key}

    _log(f"Lendo arquivo SRT s3://{bucket}/{key}", always=True)

    try:
        s3_response = s3_client.get_object(Bucket=bucket, Key=key)
        srt_bytes = s3_response["Body"].read()
        srt_text = srt_bytes.decode("utf-8", errors="ignore")
    except ClientError as e:
        _log(f"Erro ao ler SRT do S3: {e}", always=True)
        raise

    plain_text = extract_plain_text_from_srt(srt_text)
    _log(f"Tamanho do texto extraído: {len(plain_text)} caracteres")

    if not plain_text.strip():
        _log("Transcrição vazia após limpeza. Nada a fazer.", always=True)
        return {"status": "empty_transcript"}

    # Obtém o prompt (personalizado ou padrão)
    # Extrai o nome base do arquivo .srt (removendo prefixo e timestamp)
    srt_filename = key.split("/")[-1]
    video_base_name = extract_video_base_name(srt_filename)
    _log(f"Nome base do vídeo extraído: {video_base_name} (de {srt_filename})")
    system_prompt = get_system_prompt(video_base_name, bucket)
    
    # Obtém o modelo selecionado (ou usa o padrão)
    selected_model_id = get_selected_model(video_base_name, bucket)
    selected_inference_profile = get_inference_profile_for_model(selected_model_id)
    
    summary_md = call_bedrock_nova(plain_text, system_prompt, selected_model_id, selected_inference_profile)

    # Cabeçalho com modelo LLM utilizado (início do arquivo)
    model_header = f"> *Modelo LLM: {selected_model_id}*\n\n"
    summary_md = model_header + summary_md

    # Atualiza o .srt com cabeçalho indicando o modelo LLM (para rastreabilidade)
    # Remove cabeçalho existente se houver (evita duplicação em reprocessamento)
    srt_content = srt_text
    if srt_text.strip().startswith("# Modelo LLM:"):
        first_blank = srt_text.find("\n\n")
        if first_blank >= 0:
            srt_content = srt_text[first_blank + 2 :].lstrip()
    srt_header = f"# Modelo LLM: {selected_model_id}\n\n"
    srt_with_header = srt_header + srt_content
    try:
        s3_client.put_object(
            Bucket=bucket,
            Key=key,
            Body=srt_with_header.encode("utf-8"),
            ContentType="text/plain; charset=utf-8",
        )
        _log(f"Legenda atualizada com cabeçalho do modelo em s3://{bucket}/{key}")
    except ClientError as e:
        _log(f"Erro ao atualizar legenda com cabeçalho: {e}", always=True)
        # Não falha o job - o resumo é o principal

    # Mesma base do nome do arquivo .srt (usa o nome completo do .srt para o output)
    srt_base_name = key.split("/")[-1].rsplit(".", 1)[0]
    output_key = f"{OUTPUT_PREFIX}{srt_base_name}.md"

    _log(f"Gravando resumo em s3://{OUTPUT_BUCKET}/{output_key}", always=True)

    try:
        s3_client.put_object(
            Bucket=OUTPUT_BUCKET,
            Key=output_key,
            Body=summary_md.encode("utf-8"),
            ContentType="text/markdown",
        )
    except ClientError as e:
        _log(f"Erro ao gravar resumo no S3: {e}", always=True)
        raise

    print(f"[OK] Resumo gravado em s3://{OUTPUT_BUCKET}/{output_key}")
    return {
        "status": "summary_created",
        "output_bucket": OUTPUT_BUCKET,
        "output_key": output_key,
    }
