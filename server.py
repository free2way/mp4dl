from __future__ import annotations

import json
import mimetypes
import os
import re
import shutil
import subprocess
import sys
import threading
import time
import unicodedata
import uuid
from dataclasses import asdict, dataclass, field
from http import HTTPStatus
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote, urlparse

from auth import (
    credentials_are_valid,
    is_authenticated_cookie,
    login_cookie_header,
    logout_cookie_header,
)


ROOT = Path(__file__).resolve().parent
STATIC_DIR = ROOT / "static"
DOWNLOAD_DIR = ROOT / "downloads"
HOST = os.environ.get("VIDEO_DOWNLOADER_HOST", os.environ.get("X_VIDEO_HOST", "127.0.0.1"))
PORT = int(os.environ.get("VIDEO_DOWNLOADER_PORT", os.environ.get("X_VIDEO_PORT", "8765")))
SUPPORTED_DOMAINS = {
    "x.com",
    "twitter.com",
    "youtube.com",
    "youtu.be",
    "bilibili.com",
    "b23.tv",
}
COOKIE_SOURCES = {"chrome", "firefox", "safari", "edge", "brave"}
MEDIA_EXTENSIONS = {
    ".mp4",
    ".mkv",
    ".webm",
    ".mov",
    ".m4v",
    ".flv",
    ".avi",
    ".mp3",
    ".m4a",
    ".opus",
    ".aac",
}


@dataclass
class Job:
    id: str
    url: str
    download_dir: str = str(DOWNLOAD_DIR)
    status: str = "queued"
    progress: float = 0.0
    downloaded_bytes: int = 0
    total_bytes: int | None = None
    total_label: str | None = None
    message: str = "Waiting to start"
    created_at: float = field(default_factory=time.time)
    updated_at: float = field(default_factory=time.time)
    output_file: str | None = None
    output_name: str | None = None
    subtitle_files: list[str] = field(default_factory=list)
    error: str | None = None
    log: list[str] = field(default_factory=list)

    def patch(self, **values: object) -> None:
        for key, value in values.items():
            setattr(self, key, value)
        self.updated_at = time.time()

    def add_log(self, line: str) -> None:
        line = line.strip()
        if not line:
            return
        self.log.append(line)
        self.log = self.log[-80:]
        self.updated_at = time.time()


jobs: dict[str, Job] = {}
jobs_lock = threading.Lock()


def json_response(
    handler: SimpleHTTPRequestHandler,
    payload: object,
    status: int = 200,
    headers: dict[str, str] | None = None,
) -> None:
    data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    handler.send_response(status)
    handler.send_header("Content-Type", "application/json; charset=utf-8")
    handler.send_header("Content-Length", str(len(data)))
    for key, value in (headers or {}).items():
        handler.send_header(key, value)
    handler.end_headers()
    handler.wfile.write(data)


def read_json(handler: SimpleHTTPRequestHandler) -> dict[str, object]:
    length = int(handler.headers.get("Content-Length", "0"))
    if length <= 0:
        return {}
    raw = handler.rfile.read(length)
    return json.loads(raw.decode("utf-8"))


def command_exists(command: str) -> bool:
    return shutil.which(command) is not None


def yt_dlp_version() -> str | None:
    try:
        proc = subprocess.run(
            [sys.executable, "-m", "yt_dlp", "--version"],
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
    except Exception:
        return None
    if proc.returncode != 0:
        return None
    return proc.stdout.strip() or None


def system_status() -> dict[str, object]:
    return {
        "python": sys.version.split()[0],
        "ytDlpVersion": yt_dlp_version(),
        "ffmpeg": command_exists("ffmpeg"),
        "downloadDir": str(DOWNLOAD_DIR),
    }


def job_snapshot(job: Job) -> dict[str, object]:
    payload = asdict(job)
    if job.output_name:
        payload["downloadUrl"] = f"/files/{job.id}"
    return payload


def is_allowed_url(url: str) -> bool:
    try:
        parsed = urlparse(url.strip())
    except ValueError:
        return False
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        return False
    host = parsed.netloc.lower().split("@")[-1].split(":")[0]
    host = host.removeprefix("www.").removeprefix("m.")
    return any(host == domain or host.endswith(f".{domain}") for domain in SUPPORTED_DOMAINS)


def platform_name(url: str) -> str:
    host = urlparse(url).netloc.lower().split(":")[0]
    if "youtu" in host:
        return "YouTube"
    if "bilibili" in host or host.endswith("b23.tv"):
        return "Bilibili"
    if "twitter" in host or host.endswith("x.com"):
        return "X"
    return "Video"


SIZE_RE = re.compile(r"(?P<value>\d+(?:\.\d+)?)\s*(?P<unit>[KMGTPE]?i?B|B)", re.I)


def parse_size(text: str) -> int | None:
    match = SIZE_RE.search(text)
    if not match:
        return None
    value = float(match.group("value"))
    unit = match.group("unit").lower()
    multipliers = {
        "b": 1,
        "kb": 1000,
        "kib": 1024,
        "mb": 1000**2,
        "mib": 1024**2,
        "gb": 1000**3,
        "gib": 1024**3,
        "tb": 1000**4,
        "tib": 1024**4,
    }
    return int(value * multipliers.get(unit, 1))


def parse_progress_line(line: str) -> tuple[float | None, int | None, int | None]:
    percent_match = re.search(r"\[download\]\s+(\d+(?:\.\d+)?)%", line)
    percent = None
    if percent_match:
        percent = max(0.0, min(100.0, float(percent_match.group(1))))

    total = None
    total_match = re.search(r"\bof\s+~?\s*([0-9.]+\s*[KMGTPE]?i?B|[0-9.]+\s*B)", line, re.I)
    if total_match:
        total = parse_size(total_match.group(1))

    downloaded = None
    if percent is not None and total:
        downloaded = int(total * percent / 100)

    return percent, downloaded, total


def maybe_output_path(line: str, download_dir: Path) -> Path | None:
    text = line.strip().strip('"')
    if not text:
        return None
    candidate = Path(text)
    if not candidate.is_absolute():
        candidate = download_dir / candidate
    try:
        candidate.resolve().relative_to(download_dir.resolve())
    except ValueError:
        return None
    return candidate if candidate.exists() and candidate.suffix.lower() in MEDIA_EXTENSIONS else None


def newest_downloaded_file(since: float, download_dir: Path) -> Path | None:
    if not download_dir.exists():
        return None
    files = [
        path for path in download_dir.iterdir()
        if path.is_file()
        and path.stat().st_mtime >= since
        and path.suffix.lower() in MEDIA_EXTENSIONS
    ]
    if not files:
        return None
    return max(files, key=lambda path: path.stat().st_mtime)


def newest_partial_size(since: float, download_dir: Path) -> int:
    if not download_dir.exists():
        return 0
    partials = [
        path for path in download_dir.iterdir()
        if path.is_file() and path.suffix in {".part", ".ytdl"} and path.stat().st_mtime >= since
    ]
    if not partials:
        return 0
    return max(partials, key=lambda path: path.stat().st_mtime).stat().st_size


def format_bytes(size: int) -> str:
    units = ["B", "KB", "MB", "GB"]
    value = float(size)
    for unit in units:
        if value < 1024 or unit == units[-1]:
            return f"{value:.1f} {unit}" if unit != "B" else f"{int(value)} {unit}"
        value /= 1024
    return f"{size} B"


def format_size_value(size: int | None) -> str | None:
    return format_bytes(size) if isinstance(size, int) and size > 0 else None


def resolve_download_dir(raw_path: str | None) -> Path:
    if not raw_path or not raw_path.strip():
        return DOWNLOAD_DIR
    path = Path(os.path.expandvars(os.path.expanduser(raw_path.strip())))
    if not path.is_absolute():
        path = ROOT / path
    return path.resolve()


def sanitize_filename(text: str, fallback: str = "video") -> str:
    normalized = unicodedata.normalize("NFKC", text).strip()
    cleaned = re.sub(r'[\\/:*?"<>|%\r\n\t]+', " ", normalized)
    cleaned = re.sub(r"\s+", " ", cleaned).strip(" .")
    return (cleaned or fallback)[:160]


def output_base(title: str, resolution: str) -> str:
    clean_title = sanitize_filename(title, "video")
    clean_resolution = sanitize_filename(resolution, "best")
    return f"{clean_title}-{clean_resolution}"


def make_visible_path(path: Path) -> Path:
    if not path.name.startswith("."):
        return path
    target = path.with_name(f"x-{path.name.lstrip('.')}")
    if target.exists():
        return path
    path.rename(target)
    return target


def add_cookie_args(command: list[str], cookie_source: str) -> list[str]:
    if cookie_source in COOKIE_SOURCES:
        command.extend(["--cookies-from-browser", cookie_source])
    return command


def base_yt_dlp_args(cookie_source: str) -> list[str]:
    command = [
        sys.executable,
        "-m",
        "yt_dlp",
        "--no-playlist",
        "--impersonate",
        "chrome",
        "--socket-timeout",
        "20",
        "--extractor-retries",
        "2",
    ]
    return add_cookie_args(command, cookie_source)


FORMAT_VALUE_RE = re.compile(r"^fmt:[A-Za-z0-9._+\-/]+$")


def format_selector(quality: str) -> str:
    quality = quality.strip()
    if FORMAT_VALUE_RE.match(quality):
        return quality.removeprefix("fmt:")
    normalized = quality.lower()
    if normalized in {"", "best", "auto"}:
        return "bv*+ba/bestvideo+bestaudio/best"
    if normalized.isdigit():
        height = max(144, min(4320, int(normalized)))
        return f"bv*[height<={height}]+ba/b[height<={height}]/best[height<={height}]/best"
    return "bv*+ba/bestvideo+bestaudio/best"


def build_command(
    url: str,
    cookie_source: str,
    quality: str,
    download_dir: Path,
    title: str,
    resolution: str,
    include_subtitles: bool,
    subtitle_lang: str,
) -> list[str]:
    base_name = output_base(title, resolution)
    command = [
        *base_yt_dlp_args(cookie_source),
        "--newline",
        "--paths",
        str(download_dir),
        "--output",
        f"{base_name}.%(ext)s",
        "--format",
        format_selector(quality),
        "--format-sort",
        "res,br",
        "--merge-output-format",
        "mp4",
        "--print",
        "after_move:filepath",
    ]
    if include_subtitles:
        command.extend([
            "--write-subs",
            "--write-auto-subs",
            "--sub-langs",
            subtitle_lang or "all",
            "--convert-subs",
            "srt",
        ])
    command.append(url)
    return command


def format_probe_command(url: str, cookie_source: str) -> list[str]:
    return [
        *base_yt_dlp_args(cookie_source),
        "--dump-single-json",
        url,
    ]


def best_number(*values: object) -> int | None:
    for value in values:
        if isinstance(value, int) and value > 0:
            return value
        if isinstance(value, float) and value > 0:
            return int(value)
    return None


def format_rank(item: dict[str, object]) -> tuple[int, int, int]:
    return (
        best_number(item.get("tbr"), item.get("vbr"), item.get("abr")) or 0,
        best_number(item.get("filesize"), item.get("filesize_approx")) or 0,
        best_number(item.get("width")) or 0,
    )


def format_id(item: dict[str, object]) -> str | None:
    value = item.get("format_id")
    if isinstance(value, str) and value:
        return value
    return None


def exact_selector(video: dict[str, object], audio: dict[str, object] | None) -> str | None:
    video_id = format_id(video)
    if not video_id:
        return None
    if video.get("acodec") == "none" and audio:
        audio_id = format_id(audio)
        if audio_id:
            return f"fmt:{video_id}+{audio_id}"
    return f"fmt:{video_id}"


def collect_resolution_options(info: dict[str, object]) -> list[dict[str, object]]:
    grouped: dict[int, dict[str, object]] = {}
    formats = info.get("formats")
    if not isinstance(formats, list):
        formats = []

    audio_formats = [
        item for item in formats
        if isinstance(item, dict) and item.get("vcodec") == "none" and format_id(item)
    ]
    best_audio = max(audio_formats, key=format_rank, default=None)

    for item in formats:
        if not isinstance(item, dict):
            continue
        if item.get("vcodec") == "none":
            continue
        height = best_number(item.get("height"))
        if not height:
            continue
        size = best_number(item.get("filesize"), item.get("filesize_approx"))
        bitrate = best_number(item.get("tbr"), item.get("vbr"))
        if item.get("acodec") == "none" and best_audio:
            audio_size = best_number(best_audio.get("filesize"), best_audio.get("filesize_approx"))
            if size and audio_size:
                size += audio_size
            audio_bitrate = best_number(best_audio.get("abr"), best_audio.get("tbr"))
            if bitrate and audio_bitrate:
                bitrate += audio_bitrate
        selector = exact_selector(item, best_audio)
        rank = format_rank(item)
        current = grouped.get(height)
        if current is None:
            grouped[height] = {
                "value": selector or str(height),
                "height": height,
                "label": f"{height}p",
                "size": size,
                "sizeLabel": format_size_value(size),
                "bitrate": bitrate,
                "_rank": rank,
            }
            continue
        if rank > tuple(current.get("_rank", (0, 0, 0))) and selector:
            current["value"] = selector
            current["size"] = size
            current["sizeLabel"] = format_size_value(size)
            current["bitrate"] = bitrate
            current["_rank"] = rank

    options = sorted(grouped.values(), key=lambda item: int(item["height"]), reverse=True)
    for option in options:
        parts = []
        if option.get("bitrate"):
            parts.append(f"{int(option['bitrate'])}k")
        if option.get("size"):
            parts.append(format_bytes(int(option["size"])))
        option["detail"] = " / ".join(parts)
        option.pop("_rank", None)

    if options:
        best_height = int(options[0]["height"])
        return [
            {
                "value": options[0]["value"],
                "height": best_height,
                "label": f"最高画质 ({best_height}p)",
                "detail": "使用当前解析到的最高可用格式",
            },
            *options,
        ]

    height = best_number(info.get("height"))
    if height:
        return [
            {
                "value": "best",
                "height": height,
                "label": f"最高画质 ({height}p)",
                "detail": "自动选择最高可用清晰度",
            },
            {"value": str(height), "height": height, "label": f"{height}p", "detail": ""},
        ]

    return [{"value": "best", "height": None, "label": "最高画质", "detail": "自动选择最佳可用格式"}]


def collect_subtitle_options(info: dict[str, object]) -> list[dict[str, object]]:
    subtitles = info.get("subtitles")
    automatic = info.get("automatic_captions")
    options: dict[str, dict[str, object]] = {}

    def add_group(source: object, kind: str) -> None:
        if not isinstance(source, dict):
            return
        for lang, entries in source.items():
            if not isinstance(lang, str) or not lang:
                continue
            if not isinstance(entries, list) or not entries:
                continue
            label = f"{lang} ({'自动字幕' if kind == 'auto' else '字幕'})"
            value = lang
            if value not in options:
                options[value] = {"value": value, "label": label, "kind": kind}

    add_group(subtitles, "manual")
    add_group(automatic, "auto")
    values = sorted(options.values(), key=lambda item: (item["value"] != "zh-Hans", item["value"] != "zh-CN", str(item["value"])))
    if values:
        return [{"value": "all", "label": "全部可用字幕", "kind": "all"}, *values[:60]]
    return []


def probe_formats(url: str, cookie_source: str) -> tuple[dict[str, object] | None, str | None]:
    command = format_probe_command(url, cookie_source)
    try:
        proc = subprocess.run(
            command,
            cwd=ROOT,
            capture_output=True,
            text=True,
            timeout=60,
            check=False,
        )
    except subprocess.TimeoutExpired:
        return None, "解析超时。这个站点可能需要登录 Cookie，或网络连接较慢。"
    except Exception as exc:
        return None, str(exc)

    if proc.returncode != 0:
        error = (proc.stderr or proc.stdout or "解析失败").strip().splitlines()
        return None, error[-1] if error else "解析失败"

    try:
        info = json.loads(proc.stdout)
    except json.JSONDecodeError:
        return None, "无法读取 yt-dlp 返回的格式信息"

    return {
        "platform": platform_name(url),
        "title": info.get("title") or info.get("fulltitle") or "Untitled video",
        "id": info.get("id"),
        "duration": info.get("duration"),
        "thumbnail": info.get("thumbnail"),
        "formats": collect_resolution_options(info),
        "subtitles": collect_subtitle_options(info),
        "downloadDir": str(DOWNLOAD_DIR),
    }, None


def choose_directory() -> tuple[str | None, str | None]:
    if sys.platform != "darwin":
        return None, "当前目录选择器只支持 macOS；请手动输入保存路径。"
    script = 'POSIX path of (choose folder with prompt "选择视频保存目录")'
    try:
        proc = subprocess.run(
            ["osascript", "-e", script],
            capture_output=True,
            text=True,
            timeout=120,
            check=False,
        )
    except subprocess.TimeoutExpired:
        return None, "选择目录超时"
    except Exception as exc:
        return None, str(exc)
    if proc.returncode != 0:
        error = (proc.stderr or "已取消选择").strip()
        return None, error
    path = proc.stdout.strip()
    return path.rstrip("/") if path else None, None


def run_download(
    job_id: str,
    cookie_source: str,
    quality: str,
    download_dir: Path,
    title: str,
    resolution: str,
    expected_size: int | None,
    include_subtitles: bool,
    subtitle_lang: str,
) -> None:
    with jobs_lock:
        job = jobs[job_id]
        job.patch(
            status="running",
            message="Preparing downloader",
            download_dir=str(download_dir),
            total_bytes=expected_size,
            total_label=format_size_value(expected_size),
        )

    try:
        download_dir.mkdir(parents=True, exist_ok=True)
    except Exception as exc:
        with jobs_lock:
            job = jobs[job_id]
            job.patch(status="failed", error=f"无法创建保存目录：{exc}", message="Failed")
        return
    started_at = time.time()

    if yt_dlp_version() is None:
        with jobs_lock:
            job.patch(
                status="failed",
                error="yt-dlp is not installed. Run: python3 -m pip install -r requirements.txt",
                message="Missing yt-dlp",
            )
        return

    command = build_command(
        job.url,
        cookie_source,
        quality,
        download_dir,
        title,
        resolution,
        include_subtitles,
        subtitle_lang,
    )
    with jobs_lock:
        site = platform_name(job.url)
        job.patch(message=f"Connecting to {site} and selecting {resolution}")

    try:
        proc = subprocess.Popen(
            command,
            cwd=ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
        )
    except Exception as exc:
        with jobs_lock:
            job.patch(status="failed", error=str(exc), message="Could not start downloader")
        return

    def report_activity() -> None:
        while proc.poll() is None:
            time.sleep(5)
            with jobs_lock:
                job = jobs[job_id]
                if job.status != "running":
                    continue
                size = newest_partial_size(started_at, download_dir)
                if size > 0:
                    progress = job.progress
                    if job.total_bytes:
                        progress = min(99.0, size / job.total_bytes * 100)
                    job.patch(
                        progress=progress,
                        downloaded_bytes=max(job.downloaded_bytes, size),
                        message=f"Downloading, saved {format_bytes(size)}",
                    )
                elif job.progress <= 0:
                    job.patch(message="Downloading. This source may not report percent.")

    threading.Thread(target=report_activity, daemon=True).start()

    final_path: Path | None = None
    assert proc.stdout is not None
    for line in proc.stdout:
        clean = line.strip()
        progress, parsed_downloaded, parsed_total = parse_progress_line(clean)
        possible_path = maybe_output_path(clean, download_dir)
        with jobs_lock:
            job = jobs[job_id]
            job.add_log(clean)
            if progress is not None:
                total = parsed_total or job.total_bytes
                downloaded = parsed_downloaded
                if downloaded is None and total:
                    downloaded = int(total * progress / 100)
                job.patch(
                    progress=progress,
                    downloaded_bytes=max(job.downloaded_bytes, downloaded or 0),
                    total_bytes=total,
                    total_label=format_size_value(total),
                    message="Downloading",
                )
            elif "[Merger]" in clean or "[VideoRemuxer]" in clean:
                job.patch(message="Merging highest quality streams")
            elif "[ExtractAudio]" in clean:
                job.patch(message="Processing media")
        if possible_path:
            final_path = possible_path

    return_code = proc.wait()
    if final_path is None:
        final_path = newest_downloaded_file(started_at, download_dir)

    with jobs_lock:
        job = jobs[job_id]
        if return_code == 0 and final_path and final_path.exists():
            final_path = make_visible_path(final_path)
            final_size = final_path.stat().st_size
            subtitle_files = [
                str(path)
                for path in download_dir.iterdir()
                if path.is_file()
                and path != final_path
                and path.stat().st_mtime >= started_at
                and path.suffix.lower() in {".srt", ".vtt", ".ass"}
            ]
            job.patch(
                status="done",
                progress=100.0,
                downloaded_bytes=final_size,
                total_bytes=final_size,
                total_label=format_bytes(final_size),
                message="Downloaded",
                output_file=str(final_path),
                output_name=final_path.name,
                subtitle_files=subtitle_files,
            )
        else:
            hint = "Download failed"
            if not command_exists("ffmpeg"):
                hint += ". ffmpeg is missing, so best video/audio merging may fail."
            job.patch(status="failed", error=hint, message="Failed")


class AppHandler(SimpleHTTPRequestHandler):
    server_version = "VideoDownloader/1.0"
    public_static_paths = {"/login", "/login.html", "/login.js", "/styles.css", "/favicon.ico"}

    def log_message(self, format: str, *args: object) -> None:
        sys.stdout.write("%s - - [%s] %s\n" % (self.address_string(), self.log_date_time_string(), format % args))

    def is_authenticated(self) -> bool:
        return is_authenticated_cookie(self.headers.get("Cookie"))

    def redirect(self, location: str) -> None:
        self.send_response(HTTPStatus.FOUND)
        self.send_header("Location", location)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def require_auth(self, path: str) -> bool:
        if self.is_authenticated():
            return True
        if path.startswith("/api/"):
            json_response(self, {"error": "请先登录"}, HTTPStatus.UNAUTHORIZED)
            return False
        self.redirect("/login")
        return False

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        path = unquote(parsed.path)
        if path == "/api/health":
            json_response(self, {"ok": True})
            return
        if path == "/api/session":
            json_response(self, {"authenticated": self.is_authenticated()})
            return
        if path == "/login":
            if self.is_authenticated():
                self.redirect("/")
                return
            self.serve_static("/login.html")
            return
        if path in self.public_static_paths:
            self.serve_static(path)
            return
        if not self.require_auth(path):
            return
        if path == "/api/system":
            json_response(self, system_status())
            return
        if path.startswith("/api/jobs/"):
            job_id = path.rsplit("/", 1)[-1]
            with jobs_lock:
                job = jobs.get(job_id)
                if job is None:
                    json_response(self, {"error": "Job not found"}, HTTPStatus.NOT_FOUND)
                    return
                json_response(self, job_snapshot(job))
            return
        if path.startswith("/files/"):
            self.serve_download(path.removeprefix("/files/"))
            return
        self.serve_static(path)

    def do_POST(self) -> None:
        parsed = urlparse(self.path)
        if parsed.path == "/api/login":
            try:
                payload = read_json(self)
            except Exception:
                json_response(self, {"error": "Invalid JSON"}, HTTPStatus.BAD_REQUEST)
                return
            username = str(payload.get("username", "")).strip()
            password = str(payload.get("password", ""))
            if not credentials_are_valid(username, password):
                json_response(self, {"error": "用户名或密码不正确"}, HTTPStatus.UNAUTHORIZED)
                return
            json_response(
                self,
                {"ok": True},
                headers={"Set-Cookie": login_cookie_header()},
            )
            return
        if parsed.path == "/api/logout":
            json_response(
                self,
                {"ok": True},
                headers={"Set-Cookie": logout_cookie_header()},
            )
            return
        if not self.require_auth(parsed.path):
            return
        if parsed.path not in {"/api/download", "/api/formats", "/api/select-directory"}:
            json_response(self, {"error": "Not found"}, HTTPStatus.NOT_FOUND)
            return

        if parsed.path == "/api/select-directory":
            path, error = choose_directory()
            if error:
                json_response(self, {"error": error}, HTTPStatus.BAD_REQUEST)
                return
            json_response(self, {"path": path})
            return

        try:
            payload = read_json(self)
        except Exception:
            json_response(self, {"error": "Invalid JSON"}, HTTPStatus.BAD_REQUEST)
            return

        url = str(payload.get("url", "")).strip()
        cookie_source = str(payload.get("cookieSource", "none")).strip().lower()
        if not is_allowed_url(url):
            json_response(
                self,
                {"error": "请输入有效的 X、YouTube 或哔哩哔哩视频链接"},
                HTTPStatus.BAD_REQUEST,
            )
            return

        if parsed.path == "/api/formats":
            result, error = probe_formats(url, cookie_source)
            if error:
                json_response(self, {"error": error}, HTTPStatus.BAD_GATEWAY)
                return
            json_response(self, result)
            return

        quality = str(payload.get("quality", "best")).strip()
        title = str(payload.get("title", "video")).strip() or "video"
        resolution = str(payload.get("resolution", "best")).strip() or "best"
        download_dir = resolve_download_dir(str(payload.get("downloadDir", "")).strip())
        expected_size = best_number(payload.get("expectedSize"))
        include_subtitles = bool(payload.get("includeSubtitles"))
        subtitle_lang = str(payload.get("subtitleLang", "all")).strip() or "all"
        job_id = uuid.uuid4().hex
        job = Job(id=job_id, url=url, download_dir=str(download_dir))
        with jobs_lock:
            jobs[job_id] = job
        thread = threading.Thread(
            target=run_download,
            args=(
                job_id,
                cookie_source,
                quality,
                download_dir,
                title,
                resolution,
                expected_size,
                include_subtitles,
                subtitle_lang,
            ),
            daemon=True,
        )
        thread.start()
        json_response(self, job_snapshot(job), HTTPStatus.CREATED)

    def send_file(self, target: Path, attachment_name: str | None = None) -> None:
        content_type = mimetypes.guess_type(target.name)[0] or "application/octet-stream"
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(target.stat().st_size))
        if attachment_name:
            self.send_header("Content-Disposition", f'attachment; filename="{attachment_name}"')
        self.end_headers()
        with target.open("rb") as source:
            shutil.copyfileobj(source, self.wfile)

    def serve_static(self, path: str) -> None:
        if path in {"", "/"}:
            target = STATIC_DIR / "index.html"
        else:
            target = (STATIC_DIR / path.lstrip("/")).resolve()
            try:
                target.relative_to(STATIC_DIR.resolve())
            except ValueError:
                self.send_error(HTTPStatus.NOT_FOUND)
                return
        if not target.exists() or not target.is_file():
            self.send_error(HTTPStatus.NOT_FOUND)
            return
        self.send_file(target)

    def serve_download(self, filename: str) -> None:
        with jobs_lock:
            job = jobs.get(filename)
            output_file = job.output_file if job else None
        if output_file:
            target = Path(output_file).resolve()
        else:
            target = (DOWNLOAD_DIR / filename).resolve()
            try:
                target.relative_to(DOWNLOAD_DIR.resolve())
            except ValueError:
                self.send_error(HTTPStatus.NOT_FOUND)
                return
        if not target.exists() or not target.is_file():
            self.send_error(HTTPStatus.NOT_FOUND)
            return
        self.send_file(target, target.name)


def main() -> None:
    DOWNLOAD_DIR.mkdir(parents=True, exist_ok=True)
    server = ThreadingHTTPServer((HOST, PORT), AppHandler)
    print(f"Video Downloader running at http://{HOST}:{PORT}")
    print(f"Downloads folder: {DOWNLOAD_DIR}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down")
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
