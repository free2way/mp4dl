from __future__ import annotations

from pathlib import Path

from flask import Flask, Response, jsonify, request, send_from_directory

from server import (
    DOWNLOAD_DIR,
    STATIC_DIR,
    command_exists,
    is_allowed_url,
    probe_formats,
    system_status,
)


app = Flask(__name__, static_folder=None)


@app.get("/")
def index() -> Response:
    return send_from_directory(STATIC_DIR, "index.html")


@app.get("/<path:path>")
def static_files(path: str) -> Response:
    target = (STATIC_DIR / path).resolve()
    try:
        target.relative_to(STATIC_DIR.resolve())
    except ValueError:
        return jsonify({"error": "Not found"}), 404
    if target.exists() and target.is_file():
        return send_from_directory(STATIC_DIR, path)
    return jsonify({"error": "Not found"}), 404


@app.get("/api/system")
def api_system() -> Response:
    payload = system_status()
    payload["vercel"] = True
    payload["downloadDir"] = "/tmp"
    payload["localOnlyFeatures"] = [
        "选择本机保存目录",
        "后台长任务下载进度",
        "下载文件长期保存",
    ]
    return jsonify(payload)


@app.post("/api/formats")
def api_formats() -> Response:
    payload = request.get_json(silent=True) or {}
    url = str(payload.get("url", "")).strip()
    cookie_source = str(payload.get("cookieSource", "none")).strip().lower()
    if not is_allowed_url(url):
        return jsonify({"error": "请输入有效的 X、YouTube 或哔哩哔哩视频链接"}), 400

    result, error = probe_formats(url, cookie_source)
    if error:
        return jsonify({"error": error}), 502
    if result:
        result["downloadDir"] = "/tmp"
    return jsonify(result)


@app.post("/api/select-directory")
def api_select_directory() -> Response:
    return jsonify({
        "error": "Vercel 云端部署不能选择你的本机目录。请使用本地版运行 server.py 后选择目录。"
    }), 400


@app.post("/api/download")
def api_download() -> Response:
    return jsonify({
        "error": (
            "Vercel Serverless 不适合这个下载任务：无法写入你的本机目录，"
            "后台下载也可能被函数生命周期中断。请在本地运行 .venv/bin/python server.py 下载。"
        )
    }), 400


@app.get("/api/jobs/<job_id>")
def api_job(job_id: str) -> Response:
    return jsonify({"error": "Vercel 版不支持后台任务状态。请使用本地版下载。"}), 404


@app.get("/files/<path:filename>")
def api_file(filename: str) -> Response:
    return jsonify({"error": "Vercel 版不保存下载文件。请使用本地版下载。"}), 404


@app.get("/api/health")
def api_health() -> Response:
    return jsonify({
        "ok": True,
        "ytDlp": system_status().get("ytDlpVersion"),
        "ffmpeg": command_exists("ffmpeg"),
        "cwd": str(Path.cwd()),
        "tmp": "/tmp",
        "localDownloadDir": str(DOWNLOAD_DIR),
    })


if __name__ == "__main__":
    app.run(host="127.0.0.1", port=8765)
