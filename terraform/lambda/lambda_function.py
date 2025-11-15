import os
import time
import urllib.parse

import boto3

transcribe_client = boto3.client("transcribe")

OUTPUT_BUCKET = os.environ.get("TRANSCRIBE_OUTPUT_BUCKET")
OUTPUT_PREFIX = os.environ.get("TRANSCRIBE_OUTPUT_PREFIX", "transcribe/")
LANGUAGE_CODE = os.environ.get("TRANSCRIBE_LANGUAGE_CODE", "pt-BR")


def lambda_handler(event, context):
    print("Received event:", event)

    detail = event.get("detail", {})
    bucket = detail.get("bucket", {}).get("name")
    obj    = detail.get("object", {})
    key    = obj.get("key")

    if not bucket or not key:
        print("Evento sem bucket ou key")
        return {"status": "ignored"}

    key = urllib.parse.unquote_plus(key)

    if not key.lower().endswith(".mp4"):
        print(f"Ignorando {key}, não é .mp4")
        return {"status": "ignored", "key": key}

    base_name = key.split("/")[-1].rsplit(".", 1)[0]
    timestamp = int(time.time())
    job_name  = f"meetup-{base_name}-{timestamp}"[:200]

    media_uri = f"s3://{bucket}/{key}"

    print(f"Iniciando job {job_name} para {media_uri}")

    resp = transcribe_client.start_transcription_job(
        TranscriptionJobName=job_name,
        LanguageCode=LANGUAGE_CODE,
        MediaFormat="mp4",
        Media={"MediaFileUri": media_uri},
        OutputBucketName=OUTPUT_BUCKET,
        OutputKey=OUTPUT_PREFIX,
        Subtitles={"Formats": ["srt"]},
    )

    print("Resposta:", resp)

    return {"status": "started", "job_name": job_name}
