const form = document.querySelector("#download-form");
const urlInput = document.querySelector("#url");
const saveDir = document.querySelector("#save-dir");
const chooseDir = document.querySelector("#choose-dir");
const cookieSource = document.querySelector("#cookie-source");
const parseButton = document.querySelector("#parse");
const submit = document.querySelector("#submit");
const qualityField = document.querySelector("#quality-field");
const qualitySelect = document.querySelector("#quality");
const subtitleField = document.querySelector("#subtitle-field");
const includeSubtitles = document.querySelector("#include-subtitles");
const subtitleLang = document.querySelector("#subtitle-lang");
const mediaInfo = document.querySelector("#media-info");
const platform = document.querySelector("#platform");
const videoTitle = document.querySelector("#video-title");
const qualityNote = document.querySelector("#quality-note");
const statusDot = document.querySelector("#status-dot");
const statusText = document.querySelector("#status-text");
const progressText = document.querySelector("#progress-text");
const progressBar = document.querySelector("#progress-bar");
const fileLink = document.querySelector("#file-link");
const log = document.querySelector("#log");
const ytDlp = document.querySelector("#yt-dlp");
const ffmpeg = document.querySelector("#ffmpeg");
const downloadDir = document.querySelector("#download-dir");

let pollTimer = null;
let parsedForUrl = "";
let parsedPayload = null;
let formatByValue = new Map();

function formatBytes(size) {
  if (!Number.isFinite(size) || size <= 0) {
    return "";
  }
  const units = ["B", "KB", "MB", "GB", "TB"];
  let value = size;
  for (const unit of units) {
    if (value < 1024 || unit === units.at(-1)) {
      return unit === "B" ? `${Math.round(value)} ${unit}` : `${value.toFixed(1)} ${unit}`;
    }
    value /= 1024;
  }
  return `${Math.round(size)} B`;
}

function progressLabel(job, progress) {
  const downloaded = job.downloaded_bytes || 0;
  const total = job.total_bytes || 0;
  if (downloaded && total) {
    return `${progress}% · ${formatBytes(downloaded)} / ${formatBytes(total)}`;
  }
  if (downloaded) {
    return `${progress}% · ${formatBytes(downloaded)}`;
  }
  return `${progress}%`;
}

function setStatus(job) {
  const progress = Math.round(job.progress || 0);
  statusDot.className = `dot ${job.status || "idle"}`;
  statusText.textContent = job.error || job.message || job.status || "等待链接";
  progressText.textContent = progressLabel(job, progress);
  progressBar.style.width = `${progress}%`;
  log.textContent = (job.log || []).join("\n");

  if (job.status === "done" && job.downloadUrl) {
    fileLink.href = job.downloadUrl;
    fileLink.textContent = `下载文件：${job.output_name}`;
    fileLink.classList.remove("hidden");
  } else {
    fileLink.classList.add("hidden");
  }

  if (["done", "failed"].includes(job.status)) {
    submit.disabled = false;
    parseButton.disabled = false;
    submit.textContent = "开始下载";
    parseButton.textContent = "解析清晰度";
    if (pollTimer) {
      clearInterval(pollTimer);
      pollTimer = null;
    }
  }
}

function resetFormats() {
  parsedForUrl = "";
  parsedPayload = null;
  formatByValue = new Map();
  qualitySelect.innerHTML = '<option value="best">最高画质</option>';
  subtitleLang.innerHTML = '<option value="all">全部可用字幕</option>';
  includeSubtitles.checked = false;
  subtitleLang.disabled = true;
  qualityField.classList.add("hidden");
  subtitleField.classList.add("hidden");
  mediaInfo.classList.add("hidden");
}

function fillFormats(payload) {
  parsedPayload = payload;
  formatByValue = new Map();
  qualitySelect.innerHTML = "";
  for (const item of payload.formats || []) {
    const option = document.createElement("option");
    option.value = item.value;
    option.textContent = item.detail ? `${item.label} · ${item.detail}` : item.label;
    qualitySelect.append(option);
    formatByValue.set(item.value, item);
  }

  subtitleLang.innerHTML = "";
  for (const item of payload.subtitles || []) {
    const option = document.createElement("option");
    option.value = item.value;
    option.textContent = item.label;
    subtitleLang.append(option);
  }
  const hasSubtitles = (payload.subtitles || []).length > 0;
  subtitleField.classList.toggle("hidden", !hasSubtitles);
  includeSubtitles.checked = false;
  subtitleLang.disabled = true;

  qualityField.classList.remove("hidden");
  mediaInfo.classList.remove("hidden");
  platform.textContent = payload.platform || "Video";
  videoTitle.textContent = payload.title || "Untitled video";
  qualityNote.textContent = `${qualitySelect.options.length} 个清晰度 · ${hasSubtitles ? `${payload.subtitles.length} 个字幕选项` : "无字幕"}`;
  parsedForUrl = urlInput.value.trim();
}

async function refreshSystem() {
  const response = await fetch("/api/system");
  const system = await response.json();
  ytDlp.textContent = system.ytDlpVersion || "未安装";
  ffmpeg.textContent = system.ffmpeg ? "可用" : "未安装";
  downloadDir.textContent = system.downloadDir;
  saveDir.value = system.downloadDir;
}

async function parseFormats() {
  const url = urlInput.value.trim();
  if (!url) {
    throw new Error("请先输入视频链接");
  }

  parseButton.disabled = true;
  submit.disabled = true;
  parseButton.textContent = "解析中";
  setStatus({ status: "running", progress: 0, message: "正在解析可用清晰度" });

  try {
    const response = await fetch("/api/formats", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        url,
        cookieSource: cookieSource.value,
      }),
    });
    const payload = await response.json();
    if (!response.ok) {
      throw new Error(payload.error || "解析失败");
    }
    fillFormats(payload);
    setStatus({ status: "idle", progress: 0, message: "请选择清晰度" });
    return payload;
  } finally {
    parseButton.disabled = false;
    submit.disabled = false;
    parseButton.textContent = "解析清晰度";
  }
}

async function pollJob(id) {
  const response = await fetch(`/api/jobs/${id}`);
  const job = await response.json();
  setStatus(job);
}

urlInput.addEventListener("input", resetFormats);
cookieSource.addEventListener("change", resetFormats);
includeSubtitles.addEventListener("change", () => {
  subtitleLang.disabled = !includeSubtitles.checked;
});

chooseDir.addEventListener("click", async () => {
  chooseDir.disabled = true;
  chooseDir.textContent = "选择中";
  setStatus({ status: "running", progress: 0, message: "等待目录选择" });
  try {
    const response = await fetch("/api/select-directory", { method: "POST" });
    const payload = await response.json();
    if (!response.ok) {
      throw new Error(payload.error || "选择目录失败");
    }
    saveDir.value = payload.path || saveDir.value;
    setStatus({ status: "idle", progress: 0, message: "保存目录已更新" });
  } catch (error) {
    setStatus({ status: "failed", progress: 0, error: error.message });
  } finally {
    chooseDir.disabled = false;
    chooseDir.textContent = "选择目录";
  }
});

parseButton.addEventListener("click", async () => {
  fileLink.classList.add("hidden");
  log.textContent = "";
  try {
    await parseFormats();
  } catch (error) {
    setStatus({ status: "failed", progress: 0, error: error.message });
  }
});

form.addEventListener("submit", async (event) => {
  event.preventDefault();
  const url = urlInput.value.trim();
  submit.disabled = true;
  parseButton.disabled = true;
  submit.textContent = "下载中";
  fileLink.classList.add("hidden");
  log.textContent = "";
  setStatus({ status: "running", progress: 0, message: "创建任务" });

  try {
    if (parsedForUrl !== url) {
      await parseFormats();
      submit.disabled = true;
      parseButton.disabled = true;
      submit.textContent = "下载中";
    }

    const selected = formatByValue.get(qualitySelect.value) || {};
    const response = await fetch("/api/download", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        url,
        cookieSource: cookieSource.value,
        quality: qualitySelect.value,
        title: parsedPayload?.title || "video",
        resolution: selected.label || qualitySelect.options[qualitySelect.selectedIndex]?.textContent || "best",
        expectedSize: selected.size || null,
        downloadDir: saveDir.value.trim(),
        includeSubtitles: includeSubtitles.checked,
        subtitleLang: subtitleLang.value || "all",
      }),
    });
    const payload = await response.json();
    if (!response.ok) {
      throw new Error(payload.error || "创建任务失败");
    }
    setStatus(payload);
    pollTimer = setInterval(() => pollJob(payload.id), 900);
    await pollJob(payload.id);
  } catch (error) {
    setStatus({ status: "failed", progress: 0, error: error.message });
    submit.disabled = false;
    parseButton.disabled = false;
    submit.textContent = "开始下载";
  }
});

refreshSystem().catch(() => {
  ytDlp.textContent = "检查失败";
  ffmpeg.textContent = "检查失败";
  downloadDir.textContent = "检查失败";
});
