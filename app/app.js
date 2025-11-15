AWS.config.update({
  region: "us-east-2",
  credentials: new AWS.CognitoIdentityCredentials({
    IdentityPoolId: "us-east-2:2c6a2b2e-395c-452c-8f7b-c4db0346767e"
  })
});

const s3 = new AWS.S3();

const videoBucket = "aws-community-cps";
const videoPrefix = "video/";
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

let currentSelected = null;

// Dark mode
darkModeToggle.addEventListener("click", () => {
  const body = document.body;
  const dark = body.classList.contains("dark");
  body.classList.toggle("dark", !dark);
  body.classList.toggle("light", dark);
  darkModeToggle.textContent = dark ? "🌙 Dark" : "☀️ Light";
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
  const file = fileInput.files[0];

  if (!file) {
    alert("Selecione um arquivo .mp4 primeiro!");
    return;
  }

  if (!file.name.toLowerCase().endsWith(".mp4")) {
    alert("O arquivo precisa ser .mp4");
    return;
  }

  const params = {
    Bucket: videoBucket,
    Key: videoPrefix + file.name,
    Body: file,
    ContentType: "video/mp4"
  };

  uploadStatus.innerText = "Enviando vídeo...";
  uploadStatus.style.color = "";

  try {
    // Garantir que as credenciais estão carregadas
    await AWS.config.credentials.getPromise();
    
    await s3.upload(params).promise();
    uploadStatus.innerText = "✅ Upload concluído! A transcrição será gerada em alguns minutos.";
    uploadStatus.style.color = "green";
    fileInput.value = "";
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
  }
});

async function loadSRTFiles() {
  const params = { Bucket: videoBucket, Prefix: srtPrefix };
  const result = await s3.listObjectsV2(params).promise();

  srtListDiv.innerHTML = "";

  (result.Contents || []).forEach(obj => {
    if (!obj.Key.toLowerCase().endswith && !obj.Key.toLowerCase().endsWith) {} // guard
  });

  (result.Contents || []).forEach(obj => {
    if (!obj.Key.toLowerCase().endsWith(".srt")) return;

    const el = document.createElement("div");
    el.className = "file-item";
    el.textContent = obj.Key.split("/").pop();

    el.onclick = () => {
      selectItem(el, { key: obj.Key, bucket: videoBucket, type: "srt" });
      loadFilePreview(obj.Key, "srt");
    };

    srtListDiv.appendChild(el);
  });
}

async function loadMDFiles() {
  const params = { Bucket: videoBucket, Prefix: mdPrefix };
  const result = await s3.listObjectsV2(params).promise();

  mdListDiv.innerHTML = "";

  (result.Contents || []).forEach(obj => {
    if (!obj.Key.toLowerCase().endsWith(".md")) return;

    const el = document.createElement("div");
    el.className = "file-item";
    el.textContent = obj.Key.split("/").pop();

    el.onclick = () => {
      selectItem(el, { key: obj.Key, bucket: videoBucket, type: "md" });
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
    const data = await s3.getObject({ Bucket: videoBucket, Key: key }).promise();
    const text = new TextDecoder("utf-8").decode(data.Body);

    if (type === "md") {
      const html = marked.parse(text);
      previewContent.innerHTML = html;
    } else {
      previewContent.innerHTML = `<pre>${escapeHtml(text)}</pre>`;
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

loadAllLists();
setInterval(loadAllLists, 60000);
