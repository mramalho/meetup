# AWS Community - Pipeline de Transcrição e Resumo Automatizado

Sistema completo para processamento automatizado de vídeos que gera transcrições e resumos usando serviços da AWS. O projeto permite upload de vídeos através de uma interface web, processamento automático via Amazon Transcribe e geração de resumos inteligentes usando Amazon Bedrock.

## 📋 Índice

- [Visão Geral](#visão-geral)
- [Arquitetura](#arquitetura)
- [Fluxo de Dados](#fluxo-de-dados)
- [Componentes](#componentes)
- [Requisitos](#requisitos)
- [Estrutura do Projeto](#estrutura-do-projeto)
- [Configuração](#configuração)
- [Deploy](#deploy)
- [Uso](#uso)
- [Scripts Disponíveis](#scripts-disponíveis)
- [Apresentação](#apresentação)

## 🎯 Visão Geral

Este projeto automatiza o processamento completo de vídeos educacionais e palestras:

1. **Upload de Vídeos**: Interface web para upload de arquivos `.mp4`
2. **Prompt Personalizado**: Opção de enviar prompt customizado para personalizar os resumos
3. **Transcrição Automática**: Geração de legendas `.srt` via Amazon Transcribe
4. **Resumo Inteligente**: Geração de resumos em Markdown via Amazon Bedrock (DeepSeek R1)
5. **Interface Web Moderna**: Visualização avançada de Markdown com suporte a tabelas, diagramas Mermaid e syntax highlighting

## 🏗️ Arquitetura

O sistema utiliza uma arquitetura serverless na AWS, composta por:

- **Frontend**: Aplicação web estática hospedada no S3 e distribuída via CloudFront
- **Autenticação**: Cognito Identity Pool para acesso não autenticado ao S3
- **Processamento**: Funções Lambda acionadas por eventos do S3
- **IA/ML**: Amazon Transcribe para transcrição e Amazon Bedrock para resumos
- **Armazenamento**: S3 para vídeos, transcrições e resumos
- **Orquestração**: EventBridge para coordenação de eventos

### Diagrama de Arquitetura

```mermaid
graph TB
    User[👤 Usuário] -->|1. Upload vídeo| WebApp[🌐 Interface Web<br/>S3 + CloudFront]
    WebApp -->|2. Upload via Cognito| S3Video[(📦 S3 Bucket<br/>video/)]
    
    S3Video -->|3. Evento Object Created| EventBridge[⚡ EventBridge]
    EventBridge -->|4. Dispara| LambdaTranscribe[🔷 Lambda<br/>start-transcribe]
    
    LambdaTranscribe -->|5. Inicia job| Transcribe[🎙️ Amazon Transcribe]
    Transcribe -->|6. Gera .srt| S3Transcribe[(📦 S3 Bucket<br/>transcribe/)]
    
    S3Transcribe -->|7. Evento Object Created| EventBridge2[⚡ EventBridge]
    EventBridge2 -->|8. Dispara| LambdaBedrock[🔷 Lambda<br/>bedrock-summary]
    
    LambdaBedrock -->|9. Extrai texto| S3Transcribe
    LambdaBedrock -->|10. Chama modelo| Bedrock[🤖 Amazon Bedrock<br/>DeepSeek R1]
    Bedrock -->|11. Retorna resumo| LambdaBedrock
    LambdaBedrock -->|12. Salva .md| S3Resumo[(📦 S3 Bucket<br/>resumo/)]
    
    WebApp -->|13. Lista arquivos| S3Transcribe
    WebApp -->|14. Lista arquivos| S3Resumo
    WebApp -->|15. Visualiza/Download| User
    
    style User fill:#e1f5ff
    style WebApp fill:#fff4e1
    style S3Video fill:#e8f5e9
    style S3Transcribe fill:#e8f5e9
    style S3Resumo fill:#e8f5e9
    style LambdaTranscribe fill:#f3e5f5
    style LambdaBedrock fill:#f3e5f5
    style Transcribe fill:#fff9c4
    style Bedrock fill:#fff9c4
    style EventBridge fill:#ffebee
    style EventBridge2 fill:#ffebee
```

## 🔄 Fluxo de Dados

### Fluxo Completo

```mermaid
sequenceDiagram
    participant U as Usuário
    participant W as Web App
    participant S3V as S3 video/
    participant EB1 as EventBridge
    participant LT as Lambda Transcribe
    participant TR as Amazon Transcribe
    participant S3T as S3 transcribe/
    participant EB2 as EventBridge
    participant LB as Lambda Bedrock
    participant BR as Amazon Bedrock
    participant S3R as S3 resumo/

    U->>W: 1. Faz upload do vídeo .mp4 (e opcionalmente prompt)
    W->>S3V: 2. Upload vídeo para s3://bucket/video/
    W->>S3V: 2b. Upload prompt para s3://bucket/prompts/ (se fornecido)
    S3V->>EB1: 3. Dispara evento Object Created
    EB1->>LT: 4. Invoca Lambda
    LT->>TR: 5. Inicia TranscriptionJob
    TR->>S3T: 6. Salva arquivo .srt
    S3T->>EB2: 7. Dispara evento Object Created
    EB2->>LB: 8. Invoca Lambda
    LB->>S3T: 9. Lê arquivo .srt
    LB->>S3V: 9b. Tenta ler prompt personalizado (se existir)
    LB->>LB: 10. Extrai texto puro do .srt
    LB->>BR: 11. Chama Bedrock Converse API (com prompt personalizado ou padrão)
    BR->>LB: 12. Retorna resumo em Markdown
    LB->>S3R: 13. Salva arquivo .md
    U->>W: 14. Atualiza lista de arquivos
    W->>S3T: 15. Lista arquivos .srt
    W->>S3R: 16. Lista arquivos .md
    U->>W: 17. Visualiza/baixa arquivos
```

## 🧩 Componentes

### Frontend (Interface Web)

- **Localização**: `app/`
- **Tecnologias**: HTML5, CSS3, JavaScript (Vanilla)
- **Bibliotecas Externas**:
  - **Marked.js**: Renderização de Markdown
  - **Highlight.js**: Syntax highlighting para blocos de código
  - **DOMPurify**: Sanitização de HTML para segurança
  - **Mermaid.js**: Renderização de diagramas Mermaid
- **Hospedagem**: S3 + CloudFront
- **Layout**: Sidebar vertical à esquerda com preview à direita
- **Design**: Paleta monocromática (preto/cinza/branco)
- **Funcionalidades**:
  - Upload de vídeos `.mp4` via Cognito Identity Pool
  - Upload de prompt personalizado (`.txt` ou `.md`) - opcional
  - Listagem de transcrições `.srt` e resumos `.md`
  - Visualização avançada de Markdown com:
    - Suporte a GitHub Flavored Markdown (tabelas, task lists)
    - Diagramas Mermaid (flowcharts, sequence, gantt, etc.)
    - Syntax highlighting para código
    - Renderização de tabelas responsivas
  - Download e exclusão de arquivos (transcrições e resumos)
  - Modo claro/escuro
  - Botões de ação (Atualizar, Dark Mode)

### Backend (Serverless)

#### Lambda: `start-transcribe-on-s3-upload`
- **Trigger**: EventBridge (quando arquivo `.mp4` é criado em `video/`)
- **Função**: Inicia job de transcrição no Amazon Transcribe
- **Output**: Arquivo `.srt` salvo em `transcribe/`

#### Lambda: `generate-summary-from-srt-bedrock`
- **Trigger**: EventBridge (quando arquivo `.srt` é criado em `transcribe/`)
- **Função**: 
  - Extrai texto puro do arquivo `.srt`
  - Tenta ler prompt personalizado do S3 (`prompts/{nome_video}.txt`)
  - Se não encontrar, usa prompt padrão hardcoded
  - Chama Amazon Bedrock (DeepSeek R1) para gerar resumo
  - Salva resumo em Markdown em `resumo/`

### Infraestrutura AWS

- **S3 Bucket único** (`meetup-bosch`):
  - `app/`: Frontend estático
  - `model/`: Vídeos, transcrições, resumos e prompts personalizados
    - `model/video/`: Arquivos de vídeo `.mp4`
    - `model/transcribe/`: Transcrições `.srt`
    - `model/resumo/`: Resumos `.md`
    - `model/prompts/`: Prompts personalizados `.txt` (opcional)
    - `model/models/`: Modelo selecionado por vídeo (opcional)
  - `tfvars/`: State do Terraform
- **CloudFront**: CDN para distribuição do frontend
- **Route53**: DNS para domínio personalizado
- **ACM**: Certificado SSL/TLS
- **Cognito Identity Pool**: Autenticação para acesso ao S3
- **EventBridge**: Orquestração de eventos
- **IAM**: Políticas de permissão

## 📋 Requisitos

### Pré-requisitos

- **AWS CLI** configurado com credenciais válidas
- **Terraform** >= 1.6.0
- **Python** 3.12 (para desenvolvimento local)
- **Bash** (para scripts de deploy)
- **Conta AWS** com permissões para criar recursos

### Permissões AWS Necessárias

- Criar e gerenciar buckets S3
- Criar e gerenciar funções Lambda
- Criar e gerenciar EventBridge rules
- Criar e gerenciar Cognito Identity Pools
- Criar e gerenciar CloudFront distributions
- Criar e gerenciar Route53 records
- Acessar Amazon Transcribe
- Acessar Amazon Bedrock (com acesso ao modelo DeepSeek R1)

### Configuração do Bedrock

1. Acesse o console do Amazon Bedrock
2. Solicite acesso ao modelo **DeepSeek R1** (ou use outro modelo compatível)
3. Verifique que o inference profile `us.deepseek.r1-v1:0` está disponível

### Backend Terraform (state remoto)

O state do Terraform é armazenado em S3:

- **Bucket**: `meetup-bosch`
- **Path**: `tfvars/meetup/terraform.tfstate`

Antes do primeiro `terraform init`, crie o bucket (se não existir):

```bash
bash script/setup-terraform-backend.sh
```

O script aplica as mesmas práticas de segurança do projeto:
- **Block Public Access**: nenhum acesso público (state pode conter dados sensíveis)
- **Criptografia SSE-S3** (AES256)
- **Versionamento** (recuperação de state)

O `create-all.sh` executa esse passo automaticamente.

**Migração de state local para S3**: Se você já tem state local (`terraform.tfstate`), execute `terraform init` e responda `yes` quando perguntado sobre migrar o state existente.

## 📁 Estrutura do Projeto

```
meetup/
├── app/                          # Frontend estático
│   ├── index.html               # Página principal
│   ├── app.js                   # Lógica JavaScript
│   ├── models.json              # Lista de modelos Bedrock para o seletor
│   ├── styles.css               # Estilos CSS
│   ├── error.html               # Página de erro 404
│   └── assets/                 # Assets estáticos (se houver)
│
├── terraform/                    # Infraestrutura como código
│   ├── main.tf                  # Recursos principais (backend S3: s3://meetup-bosch/tfvars/meetup)
│   ├── variables.tf             # Variáveis
│   ├── outputs.tf               # Outputs (identity_pool_id, buckets, cloudfront_distribution_id)
│   ├── terraform.tfvars         # Valores (não versionado)
│   ├── lambda/
│   │   ├── lambda_function.py   # Lambda de transcrição
│   │   └── lambda_bedrock_summary.py  # Lambda de resumo
│   └── build/                   # ZIPs das Lambdas (gerados por build_lambdas.sh)
│
├── config/                       # Configurações centralizadas
│   ├── config.env.example       # Exemplo para create-all
│   └── config.json.example      # Exemplo para app (identityPoolId, bucket)
│
├── script/                       # Scripts de automação
│   ├── create-all.sh           # Cria TUDO do zero (ACM, IAM, Terraform, app)
│   ├── destroy-all.sh          # Destrói TUDO (Terraform, ACM, IAM)
│   ├── setup-terraform-backend.sh # Cria bucket S3 meetup-bosch para state (tfvars/)
│   ├── setup-acm-certificate.sh # Cria certificado ACM (us-east-1) via AWS CLI
│   ├── setup-iam-prereqs.sh     # Cria usuário IAM opcional para deploy
│   ├── update_app_config.sh    # Atualiza app.js com outputs do Terraform
│   ├── build_lambdas.sh         # Empacota as Lambdas
│   ├── terraform_deploy.sh      # terraform init + apply + update_app_config
│   └── deploy_app.sh            # Sync S3 + invalidação CloudFront (ID via Terraform)
│
├── prompt/                      # Prompts e guardrails para resumos
│   ├── prompt.md                # Exemplo de prompt personalizado
│   └── guardrails.md            # Regras obrigatórias (empacotado na Lambda)
│
├── .gitignore
├── README.md
└── PRESENTATION.md              # Base para apresentação do projeto
```

## ⚙️ Configuração

### 0. Configuração para create-all.sh (fluxo simplificado)

Se usar `create-all.sh`, crie o arquivo de configuração:

```bash
cp config/config.env.example config/config.env
```

Edite `config/config.env` e defina pelo menos:
- `DOMAIN_NAME` – domínio do site (ex: meetup.ramalho.dev.br)
- `HOSTED_ZONE_ID` – ID da hosted zone no Route53 (ou deixe vazio para descoberta automática)

Opcional: `CREATE_ACM=1`, `CREATE_IAM_USER=0`, etc. Veja `config/config.env.example` para todas as opções.

### 1. Pré-requisitos AWS (opcional: scripts com AWS CLI)

Para simplificar a criação da infraestrutura, use os scripts que criam certificado e usuário IAM via AWS CLI:

**Certificado ACM (obrigatório para HTTPS no CloudFront)**  
O certificado deve estar em **us-east-1**. Com domínio e hosted zone no Route53:

```bash
export DOMAIN_NAME="meetup.ramalho.dev.br"
export HOSTED_ZONE_ID="Z1234567890ABC"   # ID da hosted zone do domínio
bash script/setup-acm-certificate.sh
```

O script exibe o `acm_certificate_arn`; adicione-o no `terraform.tfvars`. Se não usar `HOSTED_ZONE_ID`, valide o certificado manualmente no console ACM.

**Usuário IAM para deploy (opcional)**  
Para um usuário dedicado com permissões de deploy:

```bash
export DEPLOY_USER_NAME="aws-meetup-deploy"
bash script/setup-iam-prereqs.sh
```

Depois crie uma Access Key no console IAM e use `aws configure`.

### 2. Variáveis do Terraform

Crie `terraform/terraform.tfvars`:

```hcl
aws_region         = "us-east-2"
bucket_name        = "meetup-bosch"
domain_name        = "meetup.ramalho.dev.br"
acm_certificate_arn = "arn:aws:acm:us-east-1:ACCOUNT_ID:certificate/CERT_ID"  # Saída do setup-acm-certificate.sh
hosted_zone_id     = "Z1234567890ABC"

bedrock_region            = "us-east-2"
bedrock_model_id          = "anthropic.claude-haiku-4-5-20251001-v1:0"
bedrock_inference_profile = ""   # Preencher para DeepSeek R1: "us.deepseek.r1-v1:0"
bedrock_logs_bucket_name  = ""   # Opcional. Vazio = usa {bucket_name}-bedrock-logs (logs de invocações para auditoria)
```

### 3. Configuração do Frontend

Após `terraform apply`, o script `update_app_config.sh` (executado por `terraform_deploy.sh` ou `deploy_app.sh`) gera o `config/config.json` com `identityPoolId`, `region` e `videoBucket`. O deploy copia para `app/config.json` e o `app.js` carrega em runtime. Se fizer deploy manual, rode:

```bash
bash script/update_app_config.sh
```

Para desenvolvimento local sem deploy, crie `config/config.json` manualmente (use `config/config.json.example` como base).

## 🚀 Deploy

### Opção 1: Deploy do zero (recomendado)

Um único fluxo cria certificado ACM, IAM (opcional), Terraform e frontend:

```bash
# 1. Copiar e editar a configuração
cp config/config.env.example config/config.env
nano config/config.env   # Preencha DOMAIN_NAME e HOSTED_ZONE_ID (ou deixe vazio para descoberta automática)

# 2. Criar tudo
bash script/create-all.sh
```

O `create-all.sh`:
- Descobre `HOSTED_ZONE_ID` automaticamente (se vazio e domínio no Route53)
- Cria certificado ACM via AWS CLI e valida via DNS
- Cria usuário IAM opcional para deploy
- Gera `terraform.tfvars`, faz build das Lambdas, Terraform apply e deploy do app

**Para destruir tudo** (Terraform, ACM, IAM criados pelo create-all):

```bash
bash script/destroy-all.sh
# Digite 'sim' para confirmar
# Ou: AUTO_APPROVE=1 bash script/destroy-all.sh
```

### Opção 2: Deploy manual (passo a passo)

#### 1. Build das Lambdas

```bash
bash script/build_lambdas.sh
```

Este script:
- Cria o diretório `terraform/build/` se não existir
- Empacota as funções Lambda em arquivos ZIP

#### 2. Deploy da Infraestrutura

```bash
bash script/terraform_deploy.sh
```

Ou manualmente:

```bash
cd terraform
terraform init
terraform plan
terraform apply
```

O script `terraform_deploy.sh` já roda `update_app_config.sh` ao final, atualizando o `app.js` com `identity_pool_id` e nome do bucket.

#### 3. Deploy do Frontend

```bash
bash script/deploy_app.sh
```

Este script obtém o bucket do app e o ID do CloudFront dos outputs do Terraform, faz sync do `app/` para o S3 e invalida o cache do CloudFront. Execute `terraform apply` antes da primeira vez.

## 💻 Uso

### Acessando a Interface

Após o deploy, acesse o site através do domínio configurado (ex: `https://meetup.ramalho.dev.br`).

### Upload de Vídeo

1. Clique em "Choose File" e selecione um arquivo `.mp4`
2. (Opcional) Selecione um arquivo de prompt personalizado (`.txt` ou `.md`)
   - O prompt será usado para personalizar o resumo gerado
   - Se não enviar, será usado o prompt padrão
3. Clique em "Enviar"
4. Aguarde a confirmação de upload

### Processamento Automático

O processamento acontece automaticamente:

1. **Transcrição** (alguns minutos):
   - O vídeo é processado pelo Amazon Transcribe
   - Arquivo `.srt` é gerado e salvo em `transcribe/`

2. **Resumo** (alguns minutos após a transcrição):
   - O texto é extraído do `.srt`
   - Se um prompt personalizado foi enviado, ele é lido do S3 (`prompts/{nome_video}.txt`)
   - Caso contrário, é usado o prompt padrão
   - Resumo é gerado pelo Amazon Bedrock usando o prompt selecionado
   - Arquivo `.md` é salvo em `resumo/`

### Prompt Personalizado

Você pode personalizar os resumos enviando um arquivo de prompt junto com o vídeo:

- **Formato**: Arquivo de texto (`.txt` ou `.md`)
- **Nome**: O arquivo será salvo como `{nome_do_video}.txt` no bucket
- **Uso**: O prompt será usado como instrução para o modelo de IA ao gerar o resumo
- **Exemplo**: Use `prompt/prompt.md` como base. Um prompt pode instruir o modelo a focar em pontos técnicos, criar seções específicas, ou usar um formato particular

**Nota**: Se nenhum prompt for enviado, o sistema usa o `prompt/guardrails.md` (regras obrigatórias) como base.

### Visualização

1. Use as abas "Transcrições (.srt)" e "Resumos (.md)" para alternar entre os tipos
2. Clique em um arquivo para visualizar o conteúdo
3. Os resumos Markdown suportam:
   - **Tabelas**: Renderização completa de tabelas GitHub Flavored Markdown
   - **Diagramas Mermaid**: Flowcharts, sequence diagrams, Gantt charts, etc.
   - **Syntax Highlighting**: Código com destaque de sintaxe
   - **Task Lists**: Listas de tarefas interativas
4. Use o botão "Baixar arquivo" para fazer download

## 🛠️ Scripts Disponíveis

| Script | Descrição |
|--------|-----------|
| `create-all.sh` | **Cria tudo do zero**: ACM, IAM (opcional), Terraform e deploy do app. Usa `config/config.env`. |
| `destroy-all.sh` | **⚠️ DESTRÓI TUDO**: Terraform, certificado ACM e usuário IAM (se criados pelo create-all). Confirmação digitando `sim`; use `AUTO_APPROVE=1` para pular. |
| `config/config.env.example` | Template de configuração. Copie para `config/config.env` e edite. |
| `setup-terraform-backend.sh` | Cria bucket S3 `meetup-bosch` para state remoto (path: `tfvars/meetup/terraform.tfstate`). Aplica Block Public Access, criptografia SSE-S3 e versionamento. Execute antes do primeiro `terraform init`. |
| `setup-acm-certificate.sh` | Cria certificado ACM em us-east-1 (variáveis: `DOMAIN_NAME`, opcional `HOSTED_ZONE_ID`). |
| `setup-iam-prereqs.sh` | Cria usuário IAM opcional para deploy (variável: `DEPLOY_USER_NAME`). |
| `update_app_config.sh` | Atualiza `config/config.json` com `identity_pool_id` e bucket a partir dos outputs do Terraform. |
| `build_lambdas.sh` | Empacota as Lambdas em ZIP em `terraform/build/`. |
| `terraform_deploy.sh` | `terraform init` + `apply` + `update_app_config.sh`. |
| `deploy_app.sh` | Sync do `app/` para o S3 e invalidação do CloudFront (usa outputs do Terraform). |

Exemplos:

```bash
# Fluxo simplificado (recomendado)
cp config/config.env.example config/config.env
# Edite config/config.env com DOMAIN_NAME e HOSTED_ZONE_ID
bash script/create-all.sh

# Para destruir tudo
bash script/destroy-all.sh
```

Ou deploy manual:

```bash
# Pré-requisitos (certificado e opcionalmente IAM)
DOMAIN_NAME=meetup.ramalho.dev.br HOSTED_ZONE_ID=Z... bash script/setup-acm-certificate.sh
DEPLOY_USER_NAME=aws-meetup-deploy bash script/setup-iam-prereqs.sh

# Deploy completo
bash script/build_lambdas.sh
bash script/terraform_deploy.sh
bash script/deploy_app.sh
```

## 📽️ Apresentação

O arquivo [PRESENTATION.md](PRESENTATION.md) contém um **prompt estruturado** para gerar slides em ferramentas como gamma.app: contexto do projeto, arquitetura, componentes, fluxo de dados e instruções de deploy.

## 🔧 Manutenção

### Atualizar Código das Lambdas

1. Edite os arquivos em `terraform/lambda/`
2. Execute `bash script/build_lambdas.sh`
3. Execute `terraform apply` na pasta `terraform/`

### Atualizar Frontend

1. Edite os arquivos em `app/`
2. Se adicionar novos assets, certifique-se de que estão na pasta `app/assets/`
3. Execute `bash script/deploy_app.sh`

### Verificar Logs

```bash
# Logs da Lambda de Transcrição
aws logs tail /aws/lambda/start-transcribe-on-s3-upload --follow

# Logs da Lambda de Resumo
aws logs tail /aws/lambda/generate-summary-from-srt-bedrock --follow
```

### Observabilidade (feature flags)

Para troubleshooting quando legendas ou resumos não são gerados, ative logs detalhados:

| Flag | Descrição |
|------|-----------|
| `observability_trace=1` | Log de cada etapa (bucket, key, etapas do fluxo) |
| `observability_debug=1` | Log completo do evento e respostas da API |

Em `terraform.tfvars` ou `config/config.env` (para create-all):

```hcl
observability_debug = "1"
observability_trace = "1"
```

Depois execute `terraform apply` para atualizar as Lambdas. Os logs aparecem no CloudWatch.

## 📊 Custos Estimados

Os custos variam conforme o uso, mas os principais componentes são:

- **S3**: Armazenamento e requisições (~$0.023/GB/mês)
- **Lambda**: Execuções e duração (~$0.20 por 1M requisições)
- **Transcribe**: Por minuto de áudio processado (~$0.024/minuto)
- **Bedrock**: Por token processado (varia por modelo)
- **CloudFront**: Transferência de dados (~$0.085/GB)
- **EventBridge**: Primeiros 14M eventos/mês são gratuitos

## 🔒 Segurança

- **Config em runtime**: `app.js` carrega `config.json` em runtime (gerado no deploy). Nenhum `identityPoolId` ou bucket fica hardcoded no código-fonte.
- **Cognito Identity Pool**: Acesso não autenticado com permissões limitadas apenas aos prefixos necessários.
- **CORS restrito**: Bucket aceita requisições apenas do domínio do app e do CloudFront (GET, PUT, POST, DELETE).
- **Criptografia S3**: Bucket usa SSE-S3 (AES256) para dados em repouso.
- **Security headers**: CloudFront adiciona HSTS, X-Content-Type-Options, X-Frame-Options, X-XSS-Protection, Referrer-Policy.
- **IAM Policies**: Princípio do menor privilégio aplicado.
- **S3 Bucket Policies**: CloudFront OAC para acessar `app/`; bucket privado.
- **CloudFront**: HTTPS obrigatório com certificado SSL/TLS.
- **Arquivos não versionados**: `terraform.tfvars`, `config/config.env` e `config/config.json` estão no `.gitignore`.
- **Backend Terraform**: Bucket `meetup-bosch` com Block Public Access, criptografia SSE-S3 e versionamento. O state (`tfvars/meetup/terraform.tfstate`) não fica no repositório.
- **Auditoria**: Ver `script/security-audit.md` para revisão de vulnerabilidades e correções aplicadas.

## 🐛 Troubleshooting

### Erro no Upload

- Verifique se o `config/config.json` existe e contém `identityPoolId` e `videoBucket` corretos
- Verifique as permissões do Cognito Identity Pool
- Verifique os logs do navegador (F12)

### Transcrição não é gerada

- **Causa comum**: O bucket S3 precisa ter notificação EventBridge habilitada (`aws_s3_bucket_notification` com `eventbridge = true`). Sem isso, o EventBridge não recebe eventos.
- Verifique os logs da Lambda `start-transcribe-on-s3-upload`
- Ative `observability_debug=1` no terraform.tfvars e faça `terraform apply` para ver o evento recebido

### Resumo não é gerado

- Verifique os logs da Lambda `generate-summary-from-srt-bedrock`
- Verifique se o acesso ao Bedrock está habilitado
- Verifique se o inference profile está correto
- Verifique se o prompt personalizado (se usado) está no formato correto e no bucket correto

### Site não carrega

- Verifique se o CloudFront está distribuindo corretamente
- Verifique se o certificado SSL está válido
- Verifique os logs do CloudFront

## 📝 Licença

Este projeto é fornecido como está, sem garantias.

## 🤝 Contribuindo

Contribuições são bem-vindas! Sinta-se à vontade para abrir issues ou pull requests.

## 📧 Contato

**Autor:** Marcos Ramalho

**E-mail:** mramalho@gmail.com

**LinkedIn:** [www.linkedin.com/in/ramalho.dev](https://www.linkedin.com/in/ramalho.dev)

---

**Desenvolvido com ❤️ usando AWS Serverless**


