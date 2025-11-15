#!/usr/bin/env bash
set -e

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${ROOT_DIR}/terraform"

mkdir -p "${TF_DIR}/build"

echo ">> Empacotando lambda_function.py"
cd "${TF_DIR}/lambda"
zip -q ../build/start_transcribe.zip lambda_function.py

echo ">> Empacotando lambda_bedrock_summary.py"
zip -q ../build/bedrock_summary.zip lambda_bedrock_summary.py

echo ">> Lambdas empacotadas em terraform/build/"
