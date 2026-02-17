# Prompt para Geração de Apresentação (gamma.app)

Use o texto abaixo como prompt para uma LLM no gamma.app ou similar, para gerar slides profissionais sobre o projeto.

---

## Instruções para a LLM

Gere uma apresentação em slides sobre o projeto descrito abaixo. A apresentação deve ser clara, visual e adequada para um meetup técnico ou demo. Inclua:

1. **Slide de título** – Nome do projeto e subtítulo
2. **Contexto e problema** – O que o sistema resolve
3. **Arquitetura** – Diagrama ou descrição visual dos componentes
4. **Fluxo de dados** – Sequência do processamento
5. **Componentes e tecnologias** – Tabela ou lista organizada
6. **Segurança e boas práticas** – Resumo das medidas
7. **Como colocar no ar** – Passos de deploy
8. **Slide de encerramento** – Contato e próximos passos

Mantenha os slides concisos, com bullet points e imagens/diagramas quando fizer sentido. Use linguagem técnica mas acessível.

---

## Contexto do Projeto

**Nome:** AWS Community – Pipeline de Transcrição e Resumo Automatizado

**Objetivo:** Sistema serverless na AWS que processa vídeos automaticamente: faz transcrição de áudio para legendas (.srt) e gera resumos inteligentes em Markdown usando modelos de IA (Amazon Bedrock).

**Problema que resolve:** Automatizar o trabalho manual de transcrever palestras, aulas ou vídeos técnicos e produzir resumos estruturados para estudo, documentação ou compartilhamento.

**Público-alvo:** Desenvolvedores, equipes de conteúdo, educadores e quem precisa processar vídeos em escala.

---

## Arquitetura

O sistema usa uma **arquitetura serverless event-driven** na AWS:

- **Frontend:** Aplicação web estática (HTML/CSS/JS) hospedada no S3 e distribuída via CloudFront com HTTPS
- **Autenticação:** Cognito Identity Pool (acesso não autenticado ao S3 para upload/download)
- **Armazenamento:** Um único bucket S3 (`meetup-bosch`) com prefixos:
  - `app/` – frontend
  - `model/video/` – vídeos .mp4
  - `model/transcribe/` – legendas .srt
  - `model/resumo/` – resumos .md
  - `model/prompts/` – prompts personalizados (opcional)
  - `model/models/` – modelo LLM selecionado por vídeo (opcional)
- **Orquestração:** EventBridge recebe eventos do S3 e dispara Lambdas
- **Processamento:** Duas funções Lambda em Python 3.12
- **IA/ML:** Amazon Transcribe (transcrição) e Amazon Bedrock (resumos com múltiplos modelos: Claude, Nova, DeepSeek, GPT-4o Mini)

---

## Componentes e Relacionamentos

| Componente | Função | Relaciona-se com |
|------------|--------|------------------|
| **Interface Web** | Upload de vídeo, prompt e modelo; listagem, preview, download e exclusão de transcrições e resumos | S3 (via Cognito), CloudFront |
| **S3** | Armazena vídeos, transcrições, resumos, prompts e frontend | EventBridge, Lambdas, CloudFront, Cognito |
| **EventBridge** | Dispara Lambdas quando objetos são criados no S3 | S3, Lambda Transcribe, Lambda Bedrock |
| **Lambda Transcribe** | Inicia job no Amazon Transcribe ao detectar .mp4 em `model/video/` | S3, Transcribe |
| **Amazon Transcribe** | Gera legendas .srt a partir do áudio do vídeo | Lambda Transcribe, S3 |
| **Lambda Bedrock** | Extrai texto do .srt, lê prompt/modelo do S3, chama Bedrock e salva resumo .md | S3, Bedrock |
| **Amazon Bedrock** | Gera resumo em Markdown com base na transcrição e no prompt | Lambda Bedrock |
| **CloudFront** | CDN e HTTPS para o frontend | S3 (OAC), Route53, ACM |
| **Cognito Identity Pool** | Credenciais temporárias para o app acessar o S3 | Interface Web, S3 |

---

## Fluxo de Dados (Sequência)

1. Usuário faz upload de vídeo .mp4 (e opcionalmente prompt e modelo LLM) pela interface
2. App envia arquivos ao S3 via Cognito (video → `model/video/`, prompt → `model/prompts/`, modelo → `model/models/`)
3. S3 emite evento "Object Created" para o EventBridge
4. EventBridge invoca a Lambda Transcribe
5. Lambda Transcribe inicia job no Amazon Transcribe
6. Transcribe gera .srt e salva em `model/transcribe/`
7. S3 emite novo evento; EventBridge invoca a Lambda Bedrock
8. Lambda Bedrock lê .srt, prompt (se existir) e modelo do S3
9. Lambda Bedrock chama a API Converse do Bedrock com o modelo selecionado
10. Bedrock retorna o resumo; Lambda grava .md em `model/resumo/`
11. Usuário vê transcrições e resumos na interface, pode visualizar, baixar ou excluir

---

## Tecnologias por Camada

| Camada | Tecnologias |
|--------|-------------|
| Frontend | HTML5, CSS3, JavaScript, Marked.js, Highlight.js, DOMPurify, Mermaid.js |
| Hospedagem | S3, CloudFront |
| Auth | Cognito Identity Pool |
| Orquestração | EventBridge |
| Compute | Lambda (Python 3.12) |
| IA/ML | Amazon Transcribe, Amazon Bedrock |
| Infraestrutura | Terraform, AWS CLI (ACM, IAM) |

---

## Segurança

- Config em runtime (config.json) – sem dados sensíveis no código
- CORS restrito ao domínio do app
- Criptografia SSE-S3 no bucket
- Block Public Access no bucket
- Security headers no CloudFront (HSTS, X-Content-Type-Options, etc.)
- IAM com menor privilégio
- DOMPurify para sanitizar Markdown e evitar XSS
- Limite de 2000MB no upload de vídeo

---

## Deploy Resumido

1. Copiar `config/config.env.example` para `config/config.env` e preencher DOMAIN_NAME e HOSTED_ZONE_ID
2. Executar `bash script/create-all.sh` (cria ACM, Terraform, Lambdas e deploy do app)
3. Para destruir: `bash script/destroy-all.sh`

---

## Contato

**Autor:** Marcos Ramalho  
**E-mail:** mramalho@gmail.com  
**LinkedIn:** linkedin.com/in/ramalho.dev

*Desenvolvido com AWS Serverless*
