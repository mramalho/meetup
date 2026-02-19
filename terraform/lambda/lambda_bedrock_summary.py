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


def get_selected_model_config(base_name: str, bucket: str) -> dict:
    """
    Tenta ler a config do modelo do S3 (model/models/{base_name}.json ou .txt).
    Retorna dict com id, temperature, topP, topK (valores opcionais com defaults).
    """
    # 1. Tentar .json (config completa: id, temperature, topP, topK)
    json_key = f"{MODEL_PREFIX}models/{base_name}.json"
    try:
        response = s3_client.get_object(Bucket=bucket, Key=json_key)
        data = json.loads(response["Body"].read().decode("utf-8", errors="ignore"))
        cfg = {
            "id": data.get("id", "").strip() or MODEL_ID,
            "temperature": float(data.get("temperature", 0.3)),
            "topP": float(data.get("topP", 0.9)),
            "topK": int(data.get("topK", 0)) if data.get("topK") is not None else 0,
        }
        _log(f"Modelo config lida de {json_key}: id={cfg['id']} temp={cfg['temperature']} topP={cfg['topP']}")
        return cfg
    except ClientError as e:
        if e.response.get("Error", {}).get("Code") != "NoSuchKey":
            _log(f"Erro ao ler {json_key}: {e}", always=True)
    except (json.JSONDecodeError, ValueError, TypeError) as e:
        _log(f"JSON inválido em {json_key}: {e}", always=True)

    # 2. Fallback: .txt (apenas id)
    txt_key = f"{MODEL_PREFIX}models/{base_name}.txt"
    try:
        response = s3_client.get_object(Bucket=bucket, Key=txt_key)
        model_id = response["Body"].read().decode("utf-8", errors="ignore").strip()
        _log(f"Modelo id lido de {txt_key}: {model_id}")
        return {"id": model_id or MODEL_ID, "temperature": 0.3, "topP": 0.9, "topK": 0}
    except ClientError as e:
        error_code = e.response.get("Error", {}).get("Code", "")
        if error_code == "NoSuchKey":
            _log(f"Modelo não encontrado em {json_key} nem {txt_key}, usando padrão: {MODEL_ID}")
        else:
            _log(f"Erro ao ler modelo: {e}, usando padrão: {MODEL_ID}", always=True)

    return {"id": MODEL_ID, "temperature": 0.3, "topP": 0.9, "topK": 0}


def get_model_slug(model_id: str) -> str:
    """
    Retorna slug curto do modelo para o nome do arquivo de resumo.
    Ex: CommunityDayCPS-haiku45.md, CommunityDayCPS-Novalt.md
    """
    if not model_id:
        return "default"
    mid = model_id.lower()
    if "claude-haiku" in mid or "haiku-4-5" in mid:
        return "haiku45"
    if "nova" in mid and "lite" in mid:
        return "Novalt"
    if "deepseek" in mid or "r1" in mid:
        return "DSeekR1"
    if "opus" in mid:
        return "Opus"
    if "sonnet" in mid:
        return "Sonnet"
    # Fallback: primeira parte do model_id (ex: anthropic -> anthropic)
    parts = model_id.split(".")[:2]
    return "-".join(parts).replace(":", "-")[:20] if parts else "default"


def get_inference_profile_for_model(model_id: str):
    """
    Retorna o inference profile apropriado para o modelo.
    Claude Haiku 4.5, Nova, DeepSeek e outros exigem inference profile para cross-region.
    """
    profiles = {
        "deepseek.r1-v1:0": "us.deepseek.r1-v1:0",
        "amazon.nova-2-lite-v1:0": "us.amazon.nova-2-lite-v1:0",
        # Claude Haiku 4.5: inference profile para cross-region (global. já é profile, usa direto)
        "anthropic.claude-haiku-4-5-20251001-v1:0": "us.anthropic.claude-haiku-4-5-20251001-v1:0",
    }
    return profiles.get(model_id)


def get_inference_config_for_model(model_id: str, params: dict = None) -> dict:
    """
    Retorna inferenceConfig adequado ao modelo.
    params: dict opcional com temperature, topP, topK (do models.json).
    Claude Haiku 4.5 não aceita temperature e topP juntos; usar apenas temperature.
    """
    p = params or {}
    temp = float(p.get("temperature", 0.3))
    top_p = float(p.get("topP", 0.9))
    top_k = int(p.get("topK", 0)) if p.get("topK") is not None else 0

    cfg = {"maxTokens": 2048, "temperature": temp}
    # Claude Haiku 4.5: apenas temperature (não aceita topP junto)
    if model_id and "claude-haiku-4-5" in model_id:
        return cfg
    if top_p is not None and top_p > 0:
        cfg["topP"] = top_p
    if top_k is not None and top_k > 0:
        cfg["topK"] = top_k
    return cfg


def call_bedrock_nova(transcript_text: str, system_prompt: str, model_config: dict, inference_profile: str = None) -> str:
    """
    Chama o Amazon Bedrock para gerar um resumo detalhado em Markdown.
    model_config: dict com id, temperature, topP, topK.
    """
    model_id = model_config.get("id", "")
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
        
        # Log incondicional para auditoria no CloudWatch (modelo e tamanho do input)
        print(f"[LLM] Chamando Bedrock: modelId={model_id_to_use} input_chars={len(transcript_text)}")
        _log(f"Usando modelo: {model_id_to_use} (model_id={model_id}, inference_profile={inference_profile})")
        
        inference_config = get_inference_config_for_model(model_id, model_config)
        response = bedrock_client.converse(
            modelId=model_id_to_use,
            system=[{"text": system_prompt}],
            messages=[
                {
                    "role": "user",
                    "content": [{"text": user_message}],
                }
            ],
            inferenceConfig=inference_config,
        )

        content_blocks = response["output"]["message"]["content"]
        usage = response.get("usage", {})
        input_tok = usage.get("inputTokens", "?")
        output_tok = usage.get("outputTokens", "?")
        total_tok = usage.get("totalTokens", "?")
        # pego o primeiro bloco de texto
        for block in content_blocks:
            if "text" in block:
                output_text = block["text"]
                # Log incondicional: sucesso da chamada LLM + tokens (auditoria CloudWatch)
                print(f"[LLM] Bedrock OK: output_chars={len(output_text)} inputTokens={input_tok} outputTokens={output_tok} totalTokens={total_tok}")
                return output_text

        raise RuntimeError("Resposta do modelo não contém texto.")
    except ClientError as e:
        err = e.response.get("Error", {})
        err_code = err.get("Code", "Unknown")
        err_msg = err.get("Message", str(e))
        # Fallback: se AccessDenied com inference profile, tenta modelo base (pode funcionar em algumas regiões)
        if err_code == "AccessDeniedException" and inference_profile and model_id != model_id_to_use:
            print(f"[LLM] AccessDenied com inference profile. Tentando modelo base: {model_id}")
            try:
                inference_config = get_inference_config_for_model(model_id, model_config)
                response = bedrock_client.converse(
                    modelId=model_id,
                    system=[{"text": system_prompt}],
                    messages=[{"role": "user", "content": [{"text": user_message}]}],
                    inferenceConfig=inference_config,
                )
                content_blocks = response["output"]["message"]["content"]
                for block in content_blocks:
                    if "text" in block:
                        output_text = block["text"]
                        print(f"[LLM] Bedrock OK (modelo base): output_chars={len(output_text)}")
                        return output_text
            except ClientError:
                pass  # Mantém o erro original
        print(f"[ERRO] Bedrock: code={err_code} message={err_msg}")
        _log(f"Erro ao chamar Bedrock: {e}", always=True)
        raise e


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
    
    # Obtém a config do modelo (id, temperature, topP, topK)
    model_config = get_selected_model_config(video_base_name, bucket)
    selected_model_id = model_config["id"]
    selected_inference_profile = get_inference_profile_for_model(selected_model_id)
    print(f"[MODEL] Usando modelo: {selected_model_id} (inference_profile={selected_inference_profile}) temp={model_config.get('temperature')} topP={model_config.get('topP')}")

    summary_md = call_bedrock_nova(plain_text, system_prompt, model_config, selected_inference_profile)

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

    # Legenda canônica: model/transcribe/{video_base_name}.srt (relaciona legenda ao vídeo)
    # Arquivo .video-etag armazena o ETag do vídeo no momento da transcrição (para validar se legenda ainda corresponde)
    canonical_srt_key = f"{MODEL_PREFIX}transcribe/{video_base_name}.srt"
    video_key = f"{MODEL_PREFIX}video/{video_base_name}.mp4"
    if key != canonical_srt_key:
        try:
            s3_client.put_object(
                Bucket=bucket,
                Key=canonical_srt_key,
                Body=srt_with_header.encode("utf-8"),
                ContentType="text/plain; charset=utf-8",
            )
            _log(f"Legenda canônica criada em s3://{bucket}/{canonical_srt_key}")
            # Remove o arquivo original (meetup-*-timestamp.srt) para evitar duplicata na listagem
            try:
                s3_client.delete_object(Bucket=bucket, Key=key)
                _log(f"Arquivo original removido: s3://{bucket}/{key}")
            except ClientError as e:
                _log(f"Erro ao remover arquivo original (não crítico): {e}")
            # Armazena ETag do vídeo para o frontend validar se a legenda ainda corresponde
            try:
                video_head = s3_client.head_object(Bucket=bucket, Key=video_key)
                video_etag = video_head.get("ETag", "").strip('"')
                etag_key = f"{MODEL_PREFIX}transcribe/{video_base_name}.video-etag"
                s3_client.put_object(
                    Bucket=bucket,
                    Key=etag_key,
                    Body=video_etag.encode("utf-8"),
                    ContentType="text/plain",
                )
                _log(f"ETag do vídeo armazenado em s3://{bucket}/{etag_key}")
            except ClientError:
                pass  # Vídeo pode ter sido removido; não falha o job
        except ClientError as e:
            _log(f"Erro ao criar legenda canônica: {e}", always=True)

    # Output do resumo: {video_base_name}-{model_slug}.md (permite múltiplos resumos por modelo)
    model_slug = get_model_slug(selected_model_id)
    output_key = f"{OUTPUT_PREFIX}{video_base_name}-{model_slug}.md"

    if not OUTPUT_BUCKET:
        print("[ERRO] SUMMARY_OUTPUT_BUCKET não configurado. Verifique as variáveis de ambiente da Lambda.")
        raise RuntimeError("SUMMARY_OUTPUT_BUCKET não configurado")

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
