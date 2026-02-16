# AWS Community – Pipeline de Transcrição e Resumo Automatizado

**Base para apresentação do projeto** (meetup, demo, documentação).

---

## Slide 1: Título

**AWS Community – Pipeline de Transcrição e Resumo Automatizado**

- Processamento automatizado de vídeos na AWS
- Transcrição (Transcribe) + Resumo com IA (Bedrock)
- Stack serverless: S3, Lambda, EventBridge, CloudFront, Cognito

*Apresentador | Data | AWS Community Campinas*

---

## Slide 2: O que o sistema faz?

1. **Upload** de vídeo `.mp4` (e opcionalmente prompt e modelo LLM) pela interface web
2. **Transcrição** automática → geração de legendas `.srt` (Amazon Transcribe)
3. **Resumo** em Markdown → gerado por modelo no Amazon Bedrock
4. **Visualização** de transcrições e resumos na mesma interface (Markdown, Mermaid, syntax highlight)

*Tudo disparado por eventos: sem filas manuais.*

---

## Slide 3: Arquitetura em uma frase

**Frontend (S3 + CloudFront)** envia o vídeo para **S3** → **EventBridge** dispara **Lambda Transcribe** → **Transcribe** gera `.srt` → novo evento dispara **Lambda Bedrock** → **Bedrock** gera resumo `.md` → usuário vê e baixa na mesma interface.

- Autenticação: **Cognito Identity Pool** (acesso não autenticado ao bucket)
- DNS/HTTPS: **Route53** + **ACM** + **CloudFront**

---

## Slide 4: Diagrama de alto nível

```
[Usuário] → [Web App S3+CF] → [S3 video/]
                                    ↓
[EventBridge] → [Lambda Transcribe] → [Amazon Transcribe] → [S3 transcribe/]
                                                                    ↓
[EventBridge] → [Lambda Bedrock] → [Amazon Bedrock] → [S3 resumo/]
                                                          ↓
[Usuário] ← listagem e preview ← [Web App]
```

---

## Slide 5: Tecnologias

| Camada        | Serviço / stack                          |
|---------------|------------------------------------------|
| Frontend      | HTML/CSS/JS, S3, CloudFront              |
| Auth          | Cognito Identity Pool                    |
| Orquestração  | EventBridge (regras S3 → Lambda)         |
| Processamento | Lambda (Python 3.12)                     |
| IA/ML         | Amazon Transcribe, Amazon Bedrock        |
| Infra         | Terraform, scripts AWS CLI (ACM, IAM)    |

---

## Slide 6: Fluxo do usuário

1. Acessa o site (HTTPS, domínio customizado)
2. Escolhe vídeo `.mp4`, opcionalmente prompt e modelo LLM
3. Clica em Enviar → upload via Cognito para o S3
4. Aguarda alguns minutos (transcrição + resumo automáticos)
5. Aba "Transcrições" ou "Resumos" → clica no arquivo → visualiza ou baixa

*Prompt e modelo por vídeo permitem diferentes estilos de resumo.*

---

## Slide 7: Simplificações recentes

- **Um único script** para atualizar o app: `update_app_config.sh` (Identity Pool + bucket)
- **Scripts AWS CLI** para pré-requisitos:
  - `setup-acm-certificate.sh` → certificado ACM (us-east-1)
  - `setup-iam-prereqs.sh` → usuário IAM opcional para deploy
- **Deploy do app**: `deploy_app.sh` lê bucket e CloudFront ID dos outputs do Terraform (nada hardcoded)
- **Terraform**: output `cloudfront_distribution_id` para invalidação

---

## Slide 8: Como colocar no ar (resumido)

1. **Certificado**: `DOMAIN_NAME=... HOSTED_ZONE_ID=... bash script/setup-acm-certificate.sh` → copiar ARN para `terraform.tfvars`
2. **Terraform**: preencher `terraform.tfvars` (domínio, hosted zone, ARN do certificado, Bedrock) → `bash script/build_lambdas.sh` → `bash script/terraform_deploy.sh`
3. **Frontend**: `bash script/deploy_app.sh`

*Documentação completa no README.md.*

---

## Slide 9: Segurança e custos

- **Segurança**: Cognito com permissões restritas aos prefixos do bucket; HTTPS; políticas IAM mínimas nas Lambdas
- **Custos**: S3, Lambda, Transcribe (por minuto de áudio), Bedrock (por token), CloudFront; EventBridge nos primeiros 14M eventos/mês grátis

---

## Slide 10: Próximos passos / contato

- Repositório: *(incluir link do repositório)*
- README: instruções detalhadas, troubleshooting, scripts
- **PRESENTATION.md**: esta base para slides

**Contato:** Marcos Ramalho – mramalho@gmail.com – [linkedin.com/in/ramalho.dev](https://www.linkedin.com/in/ramalho.dev)

*Desenvolvido com AWS Serverless.*
