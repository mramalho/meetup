import json
import os
import time
import urllib.parse

import boto3

transcribe_client = boto3.client("transcribe")

OUTPUT_BUCKET = os.environ.get("TRANSCRIBE_OUTPUT_BUCKET")
OUTPUT_PREFIX = os.environ.get("TRANSCRIBE_OUTPUT_PREFIX", "transcribe/")
LANGUAGE_CODE = os.environ.get("TRANSCRIBE_LANGUAGE_CODE", "pt-BR")
OBS_DEBUG = os.environ.get("OBSERVABILITY_DEBUG", "0") == "1"
OBS_TRACE = os.environ.get("OBSERVABILITY_TRACE", "0") == "1"


def _log(msg: str, always: bool = False):
    """Log controlado por feature flags. always=True ignora flags."""
    if always or OBS_TRACE or OBS_DEBUG:
        print(msg)


def lambda_handler(event, context):
    if OBS_DEBUG:
        print(f"[DEBUG] Evento recebido: {json.dumps(event, default=str)}")
    elif OBS_TRACE:
        detail = event.get("detail", {})
        bucket = detail.get("bucket", {}).get("name", "?")
        key = detail.get("object", {}).get("key", "?")
        print(f"[TRACE] Evento: bucket={bucket} key={key}")

    detail = event.get("detail", {})
    bucket = detail.get("bucket", {}).get("name")
    obj    = detail.get("object", {})
    key    = obj.get("key")

    if not bucket or not key:
        _log("Evento sem bucket ou key", always=True)
        return {"status": "ignored"}

    key = urllib.parse.unquote_plus(key)

    if not key.lower().endswith(".mp4"):
        _log(f"Ignorando {key}, não é .mp4", always=True)
        return {"status": "ignored", "key": key}

    base_name = key.split("/")[-1].rsplit(".", 1)[0]
    timestamp = int(time.time())
    job_name  = f"meetup-{base_name}-{timestamp}"[:200]

    media_uri = f"s3://{bucket}/{key}"

    _log(f"Iniciando job {job_name} para {media_uri}", always=True)

    resp = transcribe_client.start_transcription_job(
        TranscriptionJobName=job_name,
        LanguageCode=LANGUAGE_CODE,
        MediaFormat="mp4",
        Media={"MediaFileUri": media_uri},
        OutputBucketName=OUTPUT_BUCKET,
        OutputKey=OUTPUT_PREFIX,
        Subtitles={"Formats": ["srt"]},
    )

    status = resp.get("TranscriptionJob", {}).get("TranscriptionJobStatus", "UNKNOWN")
    _log(f"Job iniciado: status={status}", always=True)

    if OBS_DEBUG:
        print(f"[DEBUG] Resposta Transcribe: {json.dumps(resp, default=str)}")

    return {"status": "started", "job_name": job_name}
