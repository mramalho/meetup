import os
import urllib.parse

import boto3
from botocore.exceptions import ClientError

s3_client = boto3.client("s3")
bedrock_client = boto3.client(
    "bedrock-runtime",
    region_name=os.environ.get("BEDROCK_REGION", "us-east-2"),
)

OUTPUT_BUCKET = os.environ.get("SUMMARY_OUTPUT_BUCKET", "aws-community-cps")
OUTPUT_PREFIX = os.environ.get("SUMMARY_OUTPUT_PREFIX", "resumo/")
MODEL_ID = os.environ.get("BEDROCK_MODEL_ID", "amazon.nova-lite-v1:0")
# Para modelos que requerem inference profile (como deepseek.r1-v1:0), use o profile ID
# Trata string vazia como None (quando não há inference profile necessário)
inference_profile_raw = os.environ.get("BEDROCK_INFERENCE_PROFILE", None)
INFERENCE_PROFILE = inference_profile_raw if inference_profile_raw and inference_profile_raw.strip() else None


def extract_plain_text_from_srt(srt_str: str) -> str:
    """
    Remove numeração e timestamps do SRT,
    retornando apenas o texto das legendas.
    """
    lines = srt_str.splitlines()
    content_lines = []

    for line in lines:
        stripped = line.strip()

        # pula linhas vazias
        if not stripped:
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
    Tenta ler o prompt personalizado do S3.
    Se não encontrar, retorna o prompt padrão.
    """
    prompt_key = f"prompts/{base_name}.txt"
    
    try:
        print(f"Tentando ler prompt personalizado de s3://{bucket}/{prompt_key}")
        response = s3_client.get_object(Bucket=bucket, Key=prompt_key)
        prompt_text = response["Body"].read().decode("utf-8", errors="ignore")
        print(f"Prompt personalizado encontrado e carregado ({len(prompt_text)} caracteres)")
        return prompt_text.strip()
    except ClientError as e:
        error_code = e.response.get("Error", {}).get("Code", "")
        if error_code == "NoSuchKey":
            print(f"Prompt personalizado não encontrado em {prompt_key}, usando prompt padrão")
        elif error_code == "AccessDenied":
            print(f"Sem permissão para ler {prompt_key}, usando prompt padrão")
        else:
            print(f"Erro ao ler prompt personalizado: {e}, usando prompt padrão")
    
    # Prompt padrão
    return (
        "Você é um assistente especializado em resumir conteúdos de palestras, "
        "aulas e vídeos técnicos. Gere um resumo detalhado em português, em formato "
        "Markdown, com seções, tópicos e, se fizer sentido, bullets e subtítulos.\n\n"
        "Regras:\n"
        "- Não invente conteúdo que não esteja na transcrição.\n"
        "- Mantenha o foco nas ideias principais, exemplos importantes e conclusões.\n"
        "- Se houver passos práticos, destaque-os em listas numeradas."
    )


def get_selected_model(base_name: str, bucket: str) -> str:
    """
    Tenta ler o modelo selecionado do S3.
    Se não encontrar, retorna o modelo padrão da variável de ambiente.
    """
    model_key = f"models/{base_name}.txt"
    
    try:
        print(f"Tentando ler modelo selecionado de s3://{bucket}/{model_key}")
        response = s3_client.get_object(Bucket=bucket, Key=model_key)
        model_id = response["Body"].read().decode("utf-8", errors="ignore").strip()
        print(f"Modelo selecionado encontrado: {model_id}")
        return model_id
    except ClientError as e:
        error_code = e.response.get("Error", {}).get("Code", "")
        if error_code == "NoSuchKey":
            print(f"Modelo selecionado não encontrado em {model_key}, usando modelo padrão: {MODEL_ID}")
        elif error_code == "AccessDenied":
            print(f"Sem permissão para ler {model_key}, usando modelo padrão: {MODEL_ID}")
        else:
            print(f"Erro ao ler modelo selecionado: {e}, usando modelo padrão: {MODEL_ID}")
    
    return MODEL_ID


def get_inference_profile_for_model(model_id: str):
    """
    Retorna o inference profile apropriado para o modelo.
    DeepSeek R1 requer inference profile, outros modelos não.
    """
    if model_id == "deepseek.r1-v1:0":
        return "us.deepseek.r1-v1:0"
    return None


def call_bedrock_nova(transcript_text: str, system_prompt: str, model_id: str, inference_profile: str = None) -> str:
    """
    Chama o Amazon Bedrock para gerar
    um resumo detalhado em Markdown.
    """
    user_message = (
        "Abaixo está a transcrição (já limpa) de um vídeo. "
        "Gere um resumo detalhado em Markdown, conforme as regras.\n\n"
        "=== TRANSCRIÇÃO INÍCIO ===\n"
        f"{transcript_text}\n"
        "=== TRANSCRIÇÃO FIM ==="
    )

    try:
        # Se houver inference profile configurado, use-o como modelId
        # A API converse aceita inference profile ID como modelId
        # Caso contrário, use o model_id diretamente
        model_id_to_use = inference_profile if inference_profile else model_id
        
        print(f"Usando modelo: {model_id_to_use} (model_id={model_id}, inference_profile={inference_profile})")
        
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
        print(f"Erro ao chamar Bedrock: {e}")
        raise


def lambda_handler(event, context):
    print("Received event:", event)

    detail = event.get("detail", {})
    bucket = detail.get("bucket", {}).get("name")
    obj = detail.get("object", {})
    key = obj.get("key")

    if not bucket or not key:
        print("Evento sem bucket ou key. Nada a fazer.")
        return {"status": "ignored"}

    key = urllib.parse.unquote_plus(key)

    # Só processa arquivos .srt
    if not key.lower().endswith(".srt"):
        print(f"Ignorando objeto {key}, não é .srt.")
        return {"status": "ignored", "key": key}

    print(f"Lendo arquivo SRT s3://{bucket}/{key}")

    try:
        s3_response = s3_client.get_object(Bucket=bucket, Key=key)
        srt_bytes = s3_response["Body"].read()
        srt_text = srt_bytes.decode("utf-8", errors="ignore")
    except ClientError as e:
        print(f"Erro ao ler SRT do S3: {e}")
        raise

    plain_text = extract_plain_text_from_srt(srt_text)
    print(f"Tamanho do texto extraído: {len(plain_text)} caracteres")

    if not plain_text.strip():
        print("Transcrição vazia após limpeza. Nada a fazer.")
        return {"status": "empty_transcript"}

    # Obtém o prompt (personalizado ou padrão)
    # Extrai o nome base do arquivo .srt (removendo prefixo e timestamp)
    srt_filename = key.split("/")[-1]
    video_base_name = extract_video_base_name(srt_filename)
    print(f"Nome base do vídeo extraído: {video_base_name} (de {srt_filename})")
    system_prompt = get_system_prompt(video_base_name, bucket)
    
    # Obtém o modelo selecionado (ou usa o padrão)
    selected_model_id = get_selected_model(video_base_name, bucket)
    selected_inference_profile = get_inference_profile_for_model(selected_model_id)
    
    summary_md = call_bedrock_nova(plain_text, system_prompt, selected_model_id, selected_inference_profile)
    
    # Mesma base do nome do arquivo .srt (usa o nome completo do .srt para o output)
    srt_base_name = key.split("/")[-1].rsplit(".", 1)[0]
    output_key = f"{OUTPUT_PREFIX}{srt_base_name}.md"

    print(f"Gravando resumo em s3://{OUTPUT_BUCKET}/{output_key}")

    try:
        s3_client.put_object(
            Bucket=OUTPUT_BUCKET,
            Key=output_key,
            Body=summary_md.encode("utf-8"),
            ContentType="text/markdown",
        )
    except ClientError as e:
        print(f"Erro ao gravar resumo no S3: {e}")
        raise

    return {
        "status": "summary_created",
        "output_bucket": OUTPUT_BUCKET,
        "output_key": output_key,
    }
