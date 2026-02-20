/**
 * Config carregada em runtime de config.json (gerado no deploy).
 * Nenhum dado sensível deve ficar hardcoded no código-fonte.
 *
 * Dois mecanismos distintos:
 * 1) accessToken: controle opcional de quem pode abrir a página (comparação client-side;
 *    valor em config; ?token= na URL ou campo na tela). Não substitui o Cognito.
 * 2) Cognito Identity Pool: obtém credenciais temporárias AWS para o navegador acessar
 *    o S3 (upload, listagem, download, exclusão). Sem Cognito o front não teria como
 *    chamar o S3 de forma segura (sem expor chaves). O token só decide se a UI é exibida;
 *    o Cognito é quem autoriza as chamadas ao bucket.
 */
let config = { identityPoolId: "", region: "us-east-2", videoBucket: "", accessToken: "" };
let s3 = null;

const TOKEN_STORAGE_KEY = "meetup_access_token";

// Inicializar Mermaid (securityLevel: 'loose' necessário para diagramas; HTML é sanitizado com DOMPurify)
if (typeof mermaid !== 'undefined') {
  mermaid.initialize({
    startOnLoad: false,
    theme: 'default',
    securityLevel: 'loose',
    flowchart: {
      useMaxWidth: true,
      htmlLabels: true,
      curve: 'basis'
    },
    themeVariables: {
      primaryColor: '#333333',
      primaryTextColor: '#fff',
      primaryBorderColor: '#1a1a1a',
      lineColor: '#666666',
      secondaryColor: '#e5e5e5',
      tertiaryColor: '#f5f5f5'
    }
  });
}

const videoPrefix = "model/video/";
const promptPrefix = "model/prompts/";
const modelPrefix = "model/models/";
const srtPrefix   = "model/transcribe/";
const mdPrefix    = "model/resumo/";

const srtListDiv = document.getElementById("srtList");
const mdListDiv  = document.getElementById("mdList");
const previewContent = document.getElementById("previewContent");
const previewTitle   = document.getElementById("previewTitle");
const uploadBtn      = document.getElementById("uploadBtn");
const uploadStatus   = document.getElementById("uploadStatus");
const refreshBtn     = document.getElementById("refreshBtn");
const downloadBtn    = document.getElementById("downloadBtn");
const darkModeToggle = document.getElementById("darkModeToggle");
const tabs           = document.querySelectorAll(".tab");
const modelSelect     = document.getElementById("modelSelect");

let currentSelected = null;
let availableModels = [];

// Carregar modelos do JSON
async function loadModels() {
  try {
    const response = await fetch("models.json");
    if (!response.ok) {
      throw new Error(`Erro ao carregar models.json: ${response.status}`);
    }
    const data = await response.json();
    availableModels = data.models || [];
    
    // Limpar opções existentes
    modelSelect.innerHTML = "";
    
    // Adicionar opções dos modelos
    availableModels.forEach(model => {
      const option = document.createElement("option");
      option.value = model.id;
      option.textContent = model.name;
      if (model.description) {
        option.title = model.description;
      }
      modelSelect.appendChild(option);
    });
    
    // Selecionar o primeiro modelo por padrão
    if (availableModels.length > 0) {
      modelSelect.value = availableModels[0].id;
    }
    
    // Modelos carregados (evitar console.log em produção - pode expor estrutura)
  } catch (err) {
    console.error("Erro ao carregar modelos:", err);
    modelSelect.innerHTML = '<option value="">Erro ao carregar modelos</option>';
    // Fallback: adicionar modelos padrão em caso de erro
    const fallbackModels = [
      { id: "anthropic.claude-haiku-4-5-20251001-v1:0", temperature: 0.3, topP: 0.9, topK: 0, name: "Claude Haiku 4.5" },
      { id: "amazon.nova-lite-v1:0", temperature: 0.3, topP: 0.9, topK: 0, name: "Amazon Nova Lite" },
      { id: "deepseek.r1-v1:0", temperature: 0.5, topP: 0.9, topK: 0, name: "DeepSeek R1" }
    ];
    fallbackModels.forEach(model => {
      const option = document.createElement("option");
      option.value = model.id;
      option.textContent = model.name;
      modelSelect.appendChild(option);
    });
    availableModels = fallbackModels;
  }
}

function getTokenFromUrl() {
  const params = new URLSearchParams(window.location.search);
  return params.get("token") || "";
}

function isTokenValid(entered, expected) {
  return expected && entered && String(entered).trim() === String(expected).trim();
}

function showTokenGate() {
  const gate = document.getElementById("tokenGate");
  const container = document.querySelector(".container");
  if (gate) gate.classList.remove("hidden");
  if (container) container.classList.add("hidden");

  const tokenInput = document.getElementById("tokenInput");
  const tokenError = document.getElementById("tokenError");
  const tokenSubmit = document.getElementById("tokenSubmit");

  if (tokenSubmit) {
    tokenSubmit.onclick = () => {
      const token = tokenInput ? tokenInput.value.trim() : "";
      if (tokenError) {
        tokenError.classList.add("hidden");
        tokenError.textContent = "";
      }
      if (!token) {
        if (tokenError) {
          tokenError.textContent = "Informe o token.";
          tokenError.classList.remove("hidden");
        }
        return;
      }
      if (isTokenValid(token, config.accessToken)) {
        sessionStorage.setItem(TOKEN_STORAGE_KEY, token);
        gate.classList.add("hidden");
        container.classList.remove("hidden");
        window.history.replaceState({}, "", window.location.pathname);
        runAppInit();
      } else {
        if (tokenError) {
          tokenError.textContent = "Token inválido.";
          tokenError.classList.remove("hidden");
        }
      }
    };
  }
  if (tokenInput) {
    tokenInput.onkeydown = (e) => {
      if (e.key === "Enter") tokenSubmit && tokenSubmit.click();
    };
  }
}

async function init() {
  try {
    const res = await fetch("config.json");
    if (!res.ok) throw new Error(`config.json não encontrado (${res.status})`);
    const loaded = await res.json();
    if (!loaded.identityPoolId || !loaded.videoBucket) {
      throw new Error("config.json incompleto: identityPoolId e videoBucket são obrigatórios");
    }
    config = { ...config, ...loaded };
  } catch (err) {
    console.error("Erro ao carregar config:", err);
    const container = document.querySelector(".container");
    if (container) {
      container.innerHTML = `
        <div style="padding: 2rem; text-align: center; max-width: 500px; margin: 2rem auto;">
          <h2>⚠️ Configuração necessária</h2>
          <p>O arquivo <code>config.json</code> não foi encontrado ou está incompleto.</p>
          <p>Execute o deploy (<code>bash script/deploy_app.sh</code>) para gerar o config.json a partir dos outputs do Terraform.</p>
          <p style="color: #666; font-size: 0.9rem;">Para desenvolvimento local, crie <code>config/config.json</code> e copie para <code>app/config.json</code>, ou execute o deploy.</p>
        </div>`;
    }
    return;
  }

  if (config.accessToken) {
    const tokenFromUrl = getTokenFromUrl();
    const tokenFromStorage = sessionStorage.getItem(TOKEN_STORAGE_KEY);
    const validToken = tokenFromUrl || tokenFromStorage;
    if (validToken && isTokenValid(validToken, config.accessToken)) {
      if (tokenFromUrl) {
        sessionStorage.setItem(TOKEN_STORAGE_KEY, tokenFromUrl);
        window.history.replaceState({}, "", window.location.pathname);
      }
      runAppInit();
      return;
    }
    showTokenGate();
    return;
  }

  runAppInit();
}

async function runAppInit() {
  AWS.config.update({
    region: config.region,
    credentials: new AWS.CognitoIdentityCredentials({
      IdentityPoolId: config.identityPoolId
    })
  });
  s3 = new AWS.S3();

  await loadModels();

  darkModeToggle.addEventListener("click", () => {
    const body = document.body;
    const isDark = body.classList.contains("dark");
    body.classList.toggle("dark", !isDark);
    body.classList.toggle("light", isDark);
    darkModeToggle.textContent = isDark ? "☀️" : "🌙";
  });

// Tabs (srt/md)
tabs.forEach(tab => {
  tab.addEventListener("click", () => {
    tabs.forEach(t => t.classList.remove("active"));
    tab.classList.add("active");

    const target = tab.dataset.tab;
    if (target === "srt") {
      srtListDiv.classList.remove("hidden");
      mdListDiv.classList.add("hidden");
    } else {
      mdListDiv.classList.remove("hidden");
      srtListDiv.classList.add("hidden");
    }
  });
});

// Upload vídeo
uploadBtn.addEventListener("click", async () => {
  const fileInput = document.getElementById("videoFile");
  const promptInput = document.getElementById("promptFile");
  const videoFile = fileInput.files[0];
  const promptFile = promptInput.files[0];
  const selectedModel = modelSelect.value;
  
  // Validar se um modelo foi selecionado
  if (!selectedModel || selectedModel === "") {
    alert("Selecione um modelo LLM primeiro!");
    return;
  }

  if (!videoFile) {
    alert("Selecione um arquivo .mp4 primeiro!");
    return;
  }

  if (!videoFile.name.toLowerCase().endsWith(".mp4")) {
    alert("O arquivo precisa ser .mp4");
    return;
  }

  // Limite de tamanho: 2000MB (evitar abuso de storage)
  const MAX_SIZE_MB = 2000;
  if (videoFile.size > MAX_SIZE_MB * 1024 * 1024) {
    alert(`O arquivo excede o limite de ${MAX_SIZE_MB}MB.`);
    return;
  }

  if (promptFile) {
    const validExtensions = [".txt", ".md"];
    const fileName = promptFile.name.toLowerCase();
    if (!validExtensions.some(ext => fileName.endsWith(ext))) {
      alert("O arquivo de prompt precisa ser .txt ou .md");
      return;
    }
    const MAX_PROMPT_KB = 500;
    if (promptFile.size > MAX_PROMPT_KB * 1024) {
      alert(`O prompt excede o limite de ${MAX_PROMPT_KB}KB.`);
      return;
    }
  }

  uploadStatus.innerText = "⏳ Verificando...";
  uploadStatus.style.color = "";
  uploadStatus.className = "status-text";

  try {
    // Garantir que as credenciais estão carregadas
    await AWS.config.credentials.getPromise();

    const videoKey = videoPrefix + videoFile.name;
    const baseName = videoFile.name.split(".").slice(0, -1).join(".");
    const canonicalSrtKey = srtPrefix + baseName + ".srt";

    // Verificar se vídeo e legenda canônica já existem (legenda vinculada ao vídeo por base_name + ETag)
    let videoExisted = false;
    let subtitleValid = false;
    try {
      const videoHead = await s3.headObject({ Bucket: config.videoBucket, Key: videoKey }).promise();
      videoExisted = true;
      try {
        await s3.headObject({ Bucket: config.videoBucket, Key: canonicalSrtKey }).promise();
        const etagKey = srtPrefix + baseName + ".video-etag";
        let storedEtag = "";
        try {
          const etagObj = await s3.getObject({ Bucket: config.videoBucket, Key: etagKey }).promise();
          storedEtag = (etagObj.Body && etagObj.Body.toString()) ? etagObj.Body.toString().trim() : "";
        } catch (_) {}
        const currentEtag = (videoHead.ETag || "").replace(/"/g, "");
        subtitleValid = storedEtag && currentEtag && storedEtag === currentEtag;
      } catch (e) {
        if (e.code !== "NotFound" && e.code !== "NoSuchKey") throw e;
      }
    } catch (e) {
      if (e.code !== "NotFound" && e.code !== "NoSuchKey") throw e;
    }

    const skipTranscribe = videoExisted && subtitleValid;

    if (videoExisted && !skipTranscribe) {
      uploadStatus.innerText = "⏳ Vídeo já existe. Atualizando prompt/modelo e disparando transcrição...";
    } else if (skipTranscribe) {
      uploadStatus.innerText = "⏳ Vídeo e legenda já existem. Atualizando prompt/modelo e gerando resumo...";
    } else {
      uploadStatus.innerText = "⏳ Enviando vídeo...";
      await s3.upload({
        Bucket: config.videoBucket,
        Key: videoKey,
        Body: videoFile,
        ContentType: "video/mp4"
      }).promise();
    }

    // Upload do prompt se fornecido
    if (promptFile) {
      const promptKey = promptPrefix + baseName + ".txt";
      
      const promptParams = {
        Bucket: config.videoBucket,
        Key: promptKey,
        Body: promptFile,
        ContentType: "text/plain"
      };
      
      await s3.upload(promptParams).promise();
    }
    
    // Upload da config do modelo (id, temperature, topP, topK)
    const modelConfig = availableModels.find(m => m.id === selectedModel) || {
      id: selectedModel,
      temperature: 0.3,
      topP: 0.9,
      topK: 0
    };
    const modelKey = modelPrefix + baseName + ".json";
    const modelParams = {
      Bucket: config.videoBucket,
      Key: modelKey,
      Body: JSON.stringify({
        id: modelConfig.id,
        temperature: modelConfig.temperature ?? 0.3,
        topP: modelConfig.topP ?? 0.9,
        topK: modelConfig.topK ?? 0
      }),
      ContentType: "application/json"
    };
    
    await s3.upload(modelParams).promise();

    // Disparar pipeline conforme o caso
    if (skipTranscribe) {
      // Vídeo e legenda existem: copiar legenda para si mesma → EventBridge → Bedrock (pula Transcribe)
      // MetadataDirective REPLACE com timestamp garante que S3 emita Object Created (reprocessar com outro modelo)
      uploadStatus.innerText = "⏳ Disparando geração do resumo...";
      const copySource = `${config.videoBucket}/${canonicalSrtKey}`;
      await s3.copyObject({
        Bucket: config.videoBucket,
        Key: canonicalSrtKey,
        CopySource: copySource,
        MetadataDirective: "REPLACE",
        ContentType: "text/plain; charset=utf-8",
        Metadata: { "trigger": String(Date.now()) }
      }).promise();
    } else if (videoExisted) {
      // Vídeo existe mas legenda não/inválida: copiar vídeo → EventBridge → Transcribe → Bedrock
      uploadStatus.innerText = "⏳ Disparando transcrição e resumo...";
      const copySource = `${config.videoBucket}/${videoKey}`;
      await s3.copyObject({
        Bucket: config.videoBucket,
        Key: videoKey,
        CopySource: copySource,
        MetadataDirective: "COPY"
      }).promise();
    }

    // Mensagem de sucesso
    if (skipTranscribe) {
      uploadStatus.innerText = "✅ Vídeo e legenda já existiam. Resumo sendo gerado com o modelo selecionado. Aguarde alguns minutos.";
    } else if (videoExisted) {
      uploadStatus.innerText = "✅ Vídeo já existia. Transcrição e resumo sendo gerados. Aguarde alguns minutos.";
    } else if (promptFile) {
      uploadStatus.innerText = "✅ Upload concluído! Vídeo, prompt e modelo enviados. A transcrição será gerada em alguns minutos.";
    } else {
      uploadStatus.innerText = "✅ Upload concluído! Vídeo e modelo enviados. A transcrição será gerada em alguns minutos.";
    }
    
    uploadStatus.style.color = "green";
    uploadStatus.className = "status-text status-success";
    fileInput.value = "";
    promptInput.value = "";
    // Reset para o primeiro modelo (se houver modelos carregados)
    if (availableModels.length > 0) {
      modelSelect.value = availableModels[0].id;
    }
  } catch (err) {
    console.error("Erro no upload:", err);
    const code = err.code || err.name || "";
    const msg = err.message || "";
    let errorMsg = "❌ Erro no upload.";
    
    if (code === "NetworkError" || code === "Failed to fetch" || msg.includes("Network") || msg.includes("fetch")) {
      errorMsg += " Verifique sua conexão e CORS do bucket.";
    } else if (code === "AccessDenied" || err.statusCode === 403) {
      errorMsg += " Sem permissão. Verifique as credenciais do Cognito.";
    } else if (code === "NotFound" || code === "NoSuchKey") {
      errorMsg += " Arquivo não encontrado no bucket.";
    } else if (code === "AccessControlListNotSupported") {
      errorMsg += " Configuração do bucket incompatível.";
    } else if (code === "InvalidAccessKeyId" || code === "CredentialsError") {
      errorMsg += " Credenciais inválidas. Recarregue a página.";
    } else if (msg) {
      errorMsg += ` ${msg.substring(0, 80)}${msg.length > 80 ? "…" : ""}`;
    } else {
      errorMsg += " Abra o console (F12) para detalhes.";
    }
    
    uploadStatus.innerText = errorMsg;
    uploadStatus.style.color = "red";
    uploadStatus.className = "status-text status-error";
  }
});

async function loadFileList(prefix, ext, container) {
  const result = await s3.listObjectsV2({ Bucket: config.videoBucket, Prefix: prefix }).promise();
  container.innerHTML = "";
  (result.Contents || [])
    .filter(obj => obj.Key?.toLowerCase().endsWith(ext))
    .forEach(obj => container.appendChild(createFileItem(obj.Key, config.videoBucket, ext === ".srt" ? "srt" : "md")));
}

async function loadSRTFiles() {
  await loadFileList(srtPrefix, ".srt", srtListDiv);
}

async function loadMDFiles() {
  await loadFileList(mdPrefix, ".md", mdListDiv);
}

function createFileItem(key, bucket, type) {
  const el = document.createElement("div");
  el.className = "file-item";
  el.dataset.key = key;
  el.dataset.bucket = bucket;
  el.dataset.type = type;

  const label = document.createElement("span");
  label.className = "file-item-label";
  label.textContent = key.split("/").pop();

  const deleteBtn = document.createElement("button");
  deleteBtn.className = "file-item-delete";
  deleteBtn.title = "Excluir";
  deleteBtn.innerHTML = '<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="3 6 5 6 21 6"></polyline><path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"></path><line x1="10" y1="11" x2="10" y2="17"></line><line x1="14" y1="11" x2="14" y2="17"></line></svg>';
  deleteBtn.setAttribute("aria-label", "Excluir arquivo");

  deleteBtn.addEventListener("click", (e) => {
    e.stopPropagation();
    deleteFile(key, bucket, type, el);
  });

  el.addEventListener("click", (e) => {
    if (e.target === deleteBtn || deleteBtn.contains(e.target)) return;
    selectItem(el, { key, bucket, type });
    loadFilePreview(key, type);
  });

  el.appendChild(label);
  el.appendChild(deleteBtn);
  return el;
}

async function deleteFile(key, bucket, type, element) {
  const fileName = key.split("/").pop();
  if (!confirm(`Excluir "${fileName}"? Esta ação não pode ser desfeita.`)) return;

  try {
    await s3.deleteObject({ Bucket: bucket, Key: key }).promise();
    element.remove();
    if (currentSelected && currentSelected.key === key) {
      currentSelected = null;
      downloadBtn.disabled = true;
      previewTitle.textContent = "Preview";
      previewContent.innerHTML = "<p>Selecione um arquivo à esquerda para visualizar o conteúdo aqui.</p>";
    }
  } catch (err) {
    console.error("Erro ao excluir:", err);
    const msg = err.code === "AccessDenied" || err.statusCode === 403
      ? "Sem permissão para excluir. Execute 'terraform apply' para atualizar as permissões."
      : err.message || "Erro ao excluir arquivo. Verifique as permissões.";
    alert(msg);
  }
}

function selectItem(element, meta) {
  document.querySelectorAll(".file-item").forEach(el => el.classList.remove("selected"));
  element.classList.add("selected");
  currentSelected = meta;
  downloadBtn.disabled = false;
}

async function loadFilePreview(key, type) {
  previewTitle.textContent = "Preview - " + key.split("/").pop();
  previewContent.innerHTML = "<p>Carregando...</p>";

  try {
    const data = await s3.getObject({ Bucket: config.videoBucket, Key: key }).promise();
    const text = new TextDecoder("utf-8").decode(data.Body);

    if (type === "md") {
      // Remover wrapper ```markdown ... ``` se o Bedrock retornou o resumo dentro de code block
      let processedText = text.trim();
      const markdownWrapperRegex = /^```(?:markdown|md)?\s*\n?([\s\S]*?)```\s*$/;
      const wrapperMatch = processedText.match(markdownWrapperRegex);
      if (wrapperMatch) {
        processedText = wrapperMatch[1].trim();
      }

      // Processar blocos Mermaid antes do Markdown
      const mermaidBlocks = [];
      // Regex melhorado para capturar blocos Mermaid (com ou sem quebra de linha após mermaid)
      const mermaidRegex = /```mermaid\s*\n?([\s\S]*?)```/g;
      let match;
      let mermaidIndex = 0;
      
      // Extrair blocos Mermaid e substituir por placeholders
      while ((match = mermaidRegex.exec(processedText)) !== null) {
        const mermaidCode = match[1].trim();
        const placeholder = `\n\nMERMAID_PLACEHOLDER_${mermaidIndex}\n\n`;
        mermaidBlocks.push(mermaidCode);
        processedText = processedText.replace(match[0], placeholder);
        mermaidIndex++;
      }
      
      // Configurar marked com opções melhoradas para GFM
      if (typeof marked.setOptions === 'function') {
        marked.setOptions({
          breaks: true,
          gfm: true,
          headerIds: true,
          mangle: false,
          pedantic: false,
          sanitize: false
        });
      }

      // Renderizar Markdown
      let html = marked.parse(processedText);
      
      // Substituir placeholders por divs Mermaid (sem escape para o Mermaid processar)
      mermaidBlocks.forEach((mermaidCode, index) => {
        const placeholder = `MERMAID_PLACEHOLDER_${index}`;
        const mermaidId = `mermaid-${Date.now()}-${index}`;
        // Criar div Mermaid com o código (sem escape HTML para o Mermaid processar)
        const mermaidDiv = `<div class="mermaid" id="${mermaidId}">${mermaidCode}</div>`;
        html = html.replace(new RegExp(placeholder.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'g'), mermaidDiv);
      });
      
      // Sanitizar HTML para segurança (permitindo divs com classe mermaid e SVGs)
      const cleanHtml = DOMPurify.sanitize(html, {
        ALLOWED_TAGS: ['p', 'br', 'strong', 'em', 'u', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 
                       'ul', 'ol', 'li', 'blockquote', 'code', 'pre', 'a', 'img', 'table', 
                       'thead', 'tbody', 'tr', 'th', 'td', 'hr', 'del', 'ins', 'mark', 'div',
                       'input', 'label', 'svg', 'g', 'path', 'circle', 'rect', 'line', 'text',
                       'polygon', 'polyline', 'ellipse', 'defs', 'style', 'title'],
        ALLOWED_ATTR: ['href', 'title', 'alt', 'src', 'class', 'id', 'type', 'checked', 'for',
                       'd', 'x', 'y', 'width', 'height', 'cx', 'cy', 'r', 'fill', 'stroke',
                       'stroke-width', 'transform', 'viewBox', 'xmlns', 'points', 'x1', 'y1',
                       'x2', 'y2', 'rx', 'ry', 'style'],
        ALLOW_DATA_ATTR: false,
        KEEP_CONTENT: true
      });
      
      // Wrapper markdown-body para exibição WYSIWYG (GitHub Markdown CSS)
      previewContent.innerHTML = `<div class="markdown-body">${cleanHtml}</div>`;
      
      // Renderizar diagramas Mermaid
      if (typeof mermaid !== 'undefined' && mermaidBlocks.length > 0) {
        // Aguardar um pouco para garantir que o DOM está pronto
        setTimeout(async () => {
          const mermaidElements = previewContent.querySelectorAll('.mermaid');
          
          for (let index = 0; index < mermaidElements.length; index++) {
            const element = mermaidElements[index];
            try {
              const mermaidCode = element.textContent.trim();
              const id = element.id || `mermaid-${Date.now()}-${index}`;
              element.id = id;
              
              // Tentar usar a API moderna (async) primeiro
              if (typeof mermaid.renderAsync === 'function') {
                try {
                  const { svg } = await mermaid.renderAsync(id, mermaidCode);
                  element.innerHTML = svg;
                } catch (err) {
                  console.error('Erro ao renderizar Mermaid (async):', err);
                  throw err;
                }
              } else if (typeof mermaid.render === 'function') {
                // API com callback
                await new Promise((resolve, reject) => {
                  mermaid.render(id, mermaidCode, (svgCode, bindFunctions) => {
                    if (svgCode) {
                      element.innerHTML = svgCode;
                      if (bindFunctions) {
                        bindFunctions(element);
                      }
                      resolve();
                    } else {
                      reject(new Error('Mermaid retornou SVG vazio'));
                    }
                  });
                });
              } else if (typeof mermaid.contentLoaded === 'function') {
                // Usar contentLoaded para processar automaticamente
                mermaid.contentLoaded();
              } else {
                // Fallback: apenas exibir o código
                element.innerHTML = `<pre><code>${escapeHtml(mermaidCode)}</code></pre>`;
              }
            } catch (err) {
              console.error('Erro ao renderizar Mermaid:', err);
              const mermaidCode = mermaidBlocks[index] || element.textContent;
              element.innerHTML = `<div style="padding: 16px; background: rgba(239, 68, 68, 0.1); border-left: 4px solid var(--error); border-radius: 8px; margin: 16px 0;">
                <p style="color: var(--error); margin: 0 0 8px 0; font-weight: 600;">⚠️ Erro ao renderizar diagrama Mermaid</p>
                <p style="color: var(--text-secondary-light); margin: 0 0 12px 0; font-size: 0.9rem;">Verifique a sintaxe do diagrama.</p>
                <pre style="margin: 0; background: rgba(0,0,0,0.05); padding: 12px; border-radius: 6px;"><code>${escapeHtml(mermaidCode)}</code></pre>
              </div>`;
            }
          }
        }, 100);
      }
      
      // Aplicar syntax highlighting em blocos de código (exceto Mermaid)
      previewContent.querySelectorAll('pre code:not(.mermaid code)').forEach((block) => {
        // Não destacar se for um bloco Mermaid
        if (!block.textContent.includes('MERMAID_PLACEHOLDER')) {
          hljs.highlightElement(block);
        }
      });
    } else {
      previewContent.innerHTML = `<pre class="hljs"><code>${escapeHtml(text)}</code></pre>`;
      // Aplicar syntax highlighting mesmo para arquivos .srt
      const codeBlock = previewContent.querySelector('code');
      if (codeBlock) {
        hljs.highlightElement(codeBlock);
      }
    }
  } catch (err) {
    console.error(err);
    previewContent.innerHTML = "<p>Erro ao carregar arquivo. Veja o console.</p>";
  }
}

function escapeHtml(str) {
  return str
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}

downloadBtn.addEventListener("click", async () => {
  if (!currentSelected) return;

  try {
    const data = await s3.getObject({
      Bucket: currentSelected.bucket,
      Key: currentSelected.key
    }).promise();

    const blob = new Blob([data.Body], { type: "text/plain;charset=utf-8" });
    const url = URL.createObjectURL(blob);

    const a = document.createElement("a");
    a.href = url;
    a.download = currentSelected.key.split("/").pop();
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    URL.revokeObjectURL(url);
  } catch (err) {
    console.error(err);
    alert("Erro ao baixar arquivo. Veja o console.");
  }
});

async function loadAllLists() {
  await Promise.all([loadSRTFiles(), loadMDFiles()]);
}

  refreshBtn.addEventListener("click", loadAllLists);
  await loadAllLists();
  setInterval(loadAllLists, 60000);
}

init();
