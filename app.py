from __future__ import annotations

from pathlib import Path

from flask import Flask, Response, jsonify, make_response, redirect, request, send_from_directory

from auth import credentials_are_valid, is_authenticated_cookie, login_cookie_header, logout_cookie_header
from server import (
    DOWNLOAD_DIR,
    STATIC_DIR,
    command_exists,
    is_allowed_url,
    probe_formats,
    system_status,
)


app = Flask(__name__, static_folder=None)
PUBLIC_PATHS = {
    "/login",
    "/login.html",
    "/login.js",
    "/styles.css",
    "/favicon.ico",
    "/api/login",
    "/api/logout",
    "/api/session",
    "/api/health",
}


def request_is_authenticated() -> bool:
    return is_authenticated_cookie(request.headers.get("Cookie"))


@app.before_request
def require_login() -> Response | tuple[Response, int] | None:
    if request.path in PUBLIC_PATHS:
        return None
    if request_is_authenticated():
        return None
    if request.path.startswith("/api/"):
        return jsonify({"error": "请先登录"}), 401
    return redirect("/login")


@app.get("/login")
def login_page() -> Response:
    if request_is_authenticated():
        return redirect("/")
    return send_from_directory(STATIC_DIR, "login.html")


@app.get("/api/session")
def api_session() -> Response:
    return jsonify({"authenticated": request_is_authenticated()})


@app.post("/api/login")
def api_login() -> Response:
    payload = request.get_json(silent=True) or {}
    username = str(payload.get("username", "")).strip()
    password = str(payload.get("password", ""))
    if not credentials_are_valid(username, password):
        return jsonify({"error": "用户名或密码不正确"}), 401
    response = make_response(jsonify({"ok": True}))
    response.headers.add("Set-Cookie", login_cookie_header())
    return response


@app.post("/api/logout")
def api_logout() -> Response:
    response = make_response(jsonify({"ok": True}))
    response.headers.add("Set-Cookie", logout_cookie_header())
    return response


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
