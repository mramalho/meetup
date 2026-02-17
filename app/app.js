/**
 * Config carregada em runtime de config.json (gerado no deploy).
 * Nenhum dado sensível deve ficar hardcoded no código-fonte.
 */
let config = { identityPoolId: "", region: "us-east-2", videoBucket: "" };
let s3 = null;

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

const videoPrefix = "video/";
const promptPrefix = "prompts/";
const modelPrefix = "models/";
const srtPrefix   = "transcribe/";
const mdPrefix    = "resumo/";

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
      { id: "anthropic.claude-haiku-4-5-20251001-v1:0", name: "Claude Haiku 4.5" },
      { id: "amazon.nova-lite-v1:0", name: "Amazon Nova Lite" },
      { id: "deepseek.r1-v1:0", name: "DeepSeek R1" }
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
          <p style="color: #666; font-size: 0.9rem;">Para desenvolvimento local, crie <code>app/config.json</code> com identityPoolId, region e videoBucket.</p>
        </div>`;
    }
    return;
  }

  AWS.config.update({
    region: config.region,
    credentials: new AWS.CognitoIdentityCredentials({
      IdentityPoolId: config.identityPoolId
    })
  });
  s3 = new AWS.S3();

  await loadModels();

  // Dark mode
  darkModeToggle.addEventListener("click", () => {
  const body = document.body;
  const dark = body.classList.contains("dark");
  body.classList.toggle("dark", !dark);
  body.classList.toggle("light", dark);
  // Se estava dark, agora está light (mostra 🌙), se estava light, agora está dark (mostra ☀️)
  darkModeToggle.textContent = !dark ? "☀️" : "🌙";
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

  // Validar arquivo de prompt se fornecido
  if (promptFile) {
    const validExtensions = [".txt", ".md"];
    const fileName = promptFile.name.toLowerCase();
    const hasValidExtension = validExtensions.some(ext => fileName.endsWith(ext));
    
    if (!hasValidExtension) {
      alert("O arquivo de prompt precisa ser .txt ou .md");
      return;
    }
  }

  uploadStatus.innerText = "⏳ Enviando vídeo...";
  uploadStatus.style.color = "";
  uploadStatus.className = "status-text";

  try {
    // Garantir que as credenciais estão carregadas
    await AWS.config.credentials.getPromise();
    
    // Upload do vídeo
    const videoParams = {
      Bucket: config.videoBucket,
      Key: videoPrefix + videoFile.name,
      Body: videoFile,
      ContentType: "video/mp4"
    };
    
    await s3.upload(videoParams).promise();
    
    const baseName = videoFile.name.split(".").slice(0, -1).join(".");
    
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
    
    // Upload do modelo selecionado
    const modelKey = modelPrefix + baseName + ".txt";
    const modelParams = {
      Bucket: config.videoBucket,
      Key: modelKey,
      Body: selectedModel,
      ContentType: "text/plain"
    };
    
    await s3.upload(modelParams).promise();
    
    // Mensagem de sucesso
    if (promptFile) {
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
    let errorMsg = "❌ Erro no upload.";
    
    if (err.code === "NetworkError" || err.message?.includes("Network")) {
      errorMsg += " Verifique sua conexão.";
    } else if (err.code === "AccessDenied" || err.statusCode === 403) {
      errorMsg += " Sem permissão. Verifique as credenciais do Cognito.";
    } else if (err.message) {
      errorMsg += ` ${err.message}`;
    } else {
      errorMsg += " Veja o console para mais detalhes.";
    }
    
    uploadStatus.innerText = errorMsg;
    uploadStatus.style.color = "red";
    uploadStatus.className = "status-text status-error";
  }
});

async function loadSRTFiles() {
  const params = { Bucket: config.videoBucket, Prefix: srtPrefix };
  const result = await s3.listObjectsV2(params).promise();

  srtListDiv.innerHTML = "";

  (result.Contents || []).forEach(obj => {
    if (!obj.Key || !obj.Key.toLowerCase().endsWith(".srt")) return;

    const el = document.createElement("div");
    el.className = "file-item";
    el.textContent = obj.Key.split("/").pop();

    el.onclick = () => {
      selectItem(el, { key: obj.Key, bucket: config.videoBucket, type: "srt" });
      loadFilePreview(obj.Key, "srt");
    };

    srtListDiv.appendChild(el);
  });
}

async function loadMDFiles() {
  const params = { Bucket: config.videoBucket, Prefix: mdPrefix };
  const result = await s3.listObjectsV2(params).promise();

  mdListDiv.innerHTML = "";

  (result.Contents || []).forEach(obj => {
    if (!obj.Key || !obj.Key.toLowerCase().endsWith(".md")) return;

    const el = document.createElement("div");
    el.className = "file-item";
    el.textContent = obj.Key.split("/").pop();

    el.onclick = () => {
      selectItem(el, { key: obj.Key, bucket: config.videoBucket, type: "md" });
      loadFilePreview(obj.Key, "md");
    };

    mdListDiv.appendChild(el);
  });
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
