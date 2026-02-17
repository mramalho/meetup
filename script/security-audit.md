# Auditoria de Segurança

Este documento registra as falhas identificadas e as medidas aplicadas.

## ✅ Correções Aplicadas

### 1. Logging nas Lambdas (CloudWatch)
- **Problema**: `print("Received event:", event)` e `print("Resposta:", resp)` expunham o payload completo do EventBridge e respostas da API no CloudWatch.
- **Correção**: Removido log do evento completo. Mantido apenas log de bucket/key e status necessário para debugging.

### 2. config.json.example no S3
- **Problema**: Template com placeholders era publicado no S3, expondo a estrutura da configuração.
- **Correção**: `deploy_app.sh` agora exclui `config.json.example` do sync (`--exclude "config.json.example"`).

### 3. console.log no frontend
- **Problema**: `console.log` com quantidade de modelos poderia expor estrutura em produção.
- **Correção**: Removido console.log desnecessário.

### 4. Validação de tamanho de upload
- **Problema**: Sem limite no cliente, usuário poderia enviar arquivos enormes (abuso de storage).
- **Correção**: Adicionado limite de 2000MB no upload de vídeo.

## ✅ Medidas Já Implementadas (revisão)

| Medida | Status |
|--------|--------|
| Config em runtime (config.json) | ✅ Nenhum dado sensível hardcoded |
| CORS restrito ao domínio | ✅ |
| Criptografia S3 (CPS + backend) | ✅ |
| Block Public Access (backend) | ✅ |
| Security headers CloudFront | ✅ |
| terraform.tfvars, config.env, config.json no .gitignore | ✅ |
| DOMPurify para sanitizar Markdown | ✅ |
| IAM least privilege | ✅ |

## ⚠️ Recomendações Adicionais

1. **Rate limiting**: Cognito permite uploads ilimitados. Para produção, considere API Gateway com throttling ou WAF.

2. **Logs das Lambdas**: Os prints restantes (bucket, key, status) são úteis para debugging. Em ambiente sensível, considere log level configurável.

3. **config.json**: É público por design (Identity Pool ID deve ser conhecido pelo cliente). Não armazene secrets neste arquivo.

4. **Terraform state**: O state em S3 pode conter valores sensíveis. Garanta que o bucket `mramalho-tfvars` tenha acesso restrito apenas à conta/usuários autorizados.

## Correção: Legendas e resumos não gerados

**Causa raiz**: O bucket S3 não enviava eventos ao EventBridge. Foi adicionado `aws_s3_bucket_notification` com `eventbridge = true` no bucket CPS. Sem essa configuração, as regras EventBridge nunca recebem eventos e as Lambdas não são disparadas.

