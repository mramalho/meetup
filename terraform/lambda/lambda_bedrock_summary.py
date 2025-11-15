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
INFERENCE_PROFILE = os.environ.get("BEDROCK_INFERENCE_PROFILE", None)


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


def call_bedrock_nova(transcript_text: str) -> str:
    """
    Chama o Amazon Bedrock para gerar
    um resumo detalhado em Markdown.
    """
    system_prompt = (
        "Você é um assistente especializado em resumir conteúdos de palestras, "
        "aulas e vídeos técnicos. Gere um resumo detalhado em português, em formato "
        "Markdown, com seções, tópicos e, se fizer sentido, bullets e subtítulos.\n\n"
        "Regras:\n"
        "- Não invente conteúdo que não esteja na transcrição.\n"
        "- Mantenha o foco nas ideias principais, exemplos importantes e conclusões.\n"
        "- Se houver passos práticos, destaque-os em listas numeradas."
    )

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
        model_id_to_use = INFERENCE_PROFILE if INFERENCE_PROFILE else MODEL_ID
        
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

    summary_md = call_bedrock_nova(plain_text)

    # Mesma base do nome do arquivo .srt
    base_name = key.split("/")[-1].rsplit(".", 1)[0]
    output_key = f"{OUTPUT_PREFIX}{base_name}.md"

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
