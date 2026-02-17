#!/usr/bin/env bash
set -e

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${ROOT_DIR}/terraform"

mkdir -p "${TF_DIR}/build"

echo ">> Empacotando lambda_function.py"
cd "${TF_DIR}/lambda"
zip -q ../build/start_transcribe.zip lambda_function.py

echo ">> Empacotando lambda_bedrock_summary.py + guardrails.md (prompt padrão)"
cp "${ROOT_DIR}/prompt/guardrails.md" "${TF_DIR}/lambda/guardrails.md"
zip -q ../build/bedrock_summary.zip lambda_bedrock_summary.py guardrails.md
rm -f "${TF_DIR}/lambda/guardrails.md"

echo ">> Lambdas empacotadas em terraform/build/"
