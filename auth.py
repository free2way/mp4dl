from __future__ import annotations

import base64
import hashlib
import hmac
import os
import time
from http.cookies import SimpleCookie


AUTH_USER = os.environ.get("VIDEO_DOWNLOADER_USER", "admin")
AUTH_PASSWORD = os.environ.get("VIDEO_DOWNLOADER_PASSWORD", "admin234")
AUTH_SECRET = os.environ.get("VIDEO_DOWNLOADER_SECRET", f"mp4dl:{AUTH_USER}:{AUTH_PASSWORD}")
AUTH_COOKIE = "mp4dl_session"
AUTH_MAX_AGE = int(os.environ.get("VIDEO_DOWNLOADER_AUTH_MAX_AGE", str(7 * 24 * 60 * 60)))
AUTH_SECURE_COOKIE = os.environ.get("VIDEO_DOWNLOADER_SECURE_COOKIE", "").lower() in {"1", "true", "yes"}


def _signature(message: str) -> str:
    return hmac.new(AUTH_SECRET.encode("utf-8"), message.encode("utf-8"), hashlib.sha256).hexdigest()


def make_session_token(username: str = AUTH_USER) -> str:
    expires_at = int(time.time()) + AUTH_MAX_AGE
    message = f"{username}:{expires_at}"
    signed = f"{message}:{_signature(message)}"
    return base64.urlsafe_b64encode(signed.encode("utf-8")).decode("ascii")


def verify_session_token(token: str | None) -> bool:
    if not token:
        return False
    try:
        decoded = base64.urlsafe_b64decode(token.encode("ascii")).decode("utf-8")
        username, expires_raw, signature = decoded.rsplit(":", 2)
        expires_at = int(expires_raw)
    except Exception:
        return False
    if username != AUTH_USER or expires_at < int(time.time()):
        return False
    message = f"{username}:{expires_at}"
    return hmac.compare_digest(signature, _signature(message))


def session_from_cookie_header(cookie_header: str | None) -> str | None:
    if not cookie_header:
        return None
    cookie = SimpleCookie()
    try:
        cookie.load(cookie_header)
    except Exception:
        return None
    morsel = cookie.get(AUTH_COOKIE)
    return morsel.value if morsel else None


def is_authenticated_cookie(cookie_header: str | None) -> bool:
    return verify_session_token(session_from_cookie_header(cookie_header))


def credentials_are_valid(username: str, password: str) -> bool:
    return hmac.compare_digest(username, AUTH_USER) and hmac.compare_digest(password, AUTH_PASSWORD)


def login_cookie_header() -> str:
    parts = [
        f"{AUTH_COOKIE}={make_session_token()}",
        "Path=/",
        f"Max-Age={AUTH_MAX_AGE}",
        "HttpOnly",
        "SameSite=Lax",
    ]
    if AUTH_SECURE_COOKIE:
        parts.append("Secure")
    return "; ".join(parts)


def logout_cookie_header() -> str:
    return f"{AUTH_COOKIE}=; Path=/; Max-Age=0; HttpOnly; SameSite=Lax"
