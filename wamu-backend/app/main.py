"""
WAMU FastAPI entrypoint.

Thin app factory: middleware + routers. Business logic lives in services/.
"""

from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.middleware.gzip import GZipMiddleware
from fastapi.responses import HTMLResponse, JSONResponse, Response
from fastapi.staticfiles import StaticFiles

from app.api.v1 import api_router
from app.core.config import get_settings
from app.core.logging import new_request_id, request_id_ctx, setup_logging
from app.core.media_urls import public_origin, rewrite_media_tree
from app.core.rate_limit import is_rate_limited

settings = get_settings()
_MEDIA_ROOT = Path(__file__).resolve().parents[1] / "media_uploads"
# Flutter web build (phone demo): repo dist/web → served at /
_WEB_ROOT = Path(__file__).resolve().parents[2] / "dist" / "web"


@asynccontextmanager
async def lifespan(_app: FastAPI):
    from app.core.config import validate_runtime_settings
    from app.core.realtime import manager as realtime_manager
    from app.core.sentry_setup import init_sentry

    validate_runtime_settings()
    setup_logging(settings.debug)
    init_sentry(dsn=settings.sentry_dsn or None, environment=settings.environment)
    _MEDIA_ROOT.mkdir(parents=True, exist_ok=True)
    await realtime_manager.start()
    from scripts.bootstrap import bootstrap

    await bootstrap()
    yield
    await realtime_manager.stop()


app = FastAPI(
    title="WAMU API",
    description="Uganda Super App — Connect. Discover. Do More.",
    version="0.1.0",
    lifespan=lifespan,
)

# Local demo media (when MinIO is not running)
_MEDIA_ROOT.mkdir(parents=True, exist_ok=True)
app.mount("/media-files", StaticFiles(directory=str(_MEDIA_ROOT)), name="media-files")

_cors = [o for o in (settings.cors_origins or []) if o]
if settings.is_production and ("*" in _cors or not _cors):
    raise RuntimeError("Refusing to start: unsafe CORS in production")
# Dev: allow Flutter web on any localhost / 127.0.0.1 port (chrome --web-port=5188, etc.)
_cors_kwargs: dict = {
    "allow_origins": _cors or ["http://localhost:3000"],
    "allow_credentials": True,
    "allow_methods": ["*"],
    "allow_headers": ["*"],
}
if not settings.is_production:
    # Phone demo tunnels (same-origin Flutter is fine; this helps admin :3000 → tunnel API).
    _cors_kwargs["allow_origin_regex"] = (
        r"https?://(localhost|127\.0\.0\.1)(:\d+)?|"
        r"https://[a-z0-9-]+\.(trycloudflare\.com|loca\.lt|lhr\.life)"
    )
app.add_middleware(CORSMiddleware, **_cors_kwargs)
# Shrink Flutter JS/JSON over the phone tunnel (main.dart.js ~4.5MB → ~1MB).
app.add_middleware(GZipMiddleware, minimum_size=500)


@app.middleware("http")
async def static_cache_middleware(request: Request, call_next):
    """Long-cache hashed Flutter assets + media; never cache index.html (demo refresh)."""
    response = await call_next(request)
    path = request.url.path
    if path in ("/", "/index.html") or path.endswith("/index.html"):
        response.headers["Cache-Control"] = "no-cache, no-store, must-revalidate"
    elif path.startswith("/media-files/"):
        # Posters + compressed MP4s are content-addressed by UUID filename.
        response.headers.setdefault("Cache-Control", "public, max-age=604800, immutable")
        response.headers.setdefault("Accept-Ranges", "bytes")
    elif path.startswith("/canvaskit/") or path.startswith("/assets/") or path.endswith(
        (".js", ".wasm", ".woff2", ".woff", ".ttf", ".otf")
    ):
        if not path.startswith("/api/"):
            response.headers.setdefault(
                "Cache-Control", "public, max-age=86400, immutable"
            )
    return response


@app.middleware("http")
async def request_id_middleware(request: Request, call_next):
    from app.core.metrics import HTTP_REQUESTS, metrics

    rid = request.headers.get("X-Request-ID") or new_request_id()
    token = request_id_ctx.set(rid)
    try:
        if request.url.path.startswith("/api/"):
            metrics.incr(HTTP_REQUESTS)
        response = await call_next(request)
        response.headers["X-Request-ID"] = rid
        return response
    finally:
        request_id_ctx.reset(token)


@app.middleware("http")
async def rate_limit_middleware(request: Request, call_next):
    # Skip health/docs; local demo polls chats+notifs heavily (IndexedStack).
    path = request.url.path
    if path.startswith("/api/") and path not in {
        "/api/v1/health",
        "/api/health",
        "/api",
    }:
        # Development / mock OTP: allow denser client polling without 429 spam.
        limit = settings.rate_limit_api_per_minute
        if settings.debug or settings.otp_mock_mode or settings.environment == "development":
            limit = max(limit, 600)
        ip = request.client.host if request.client else "unknown"
        if await is_rate_limited(f"api:{ip}", limit, 60):
            return JSONResponse({"detail": "Rate limit exceeded"}, status_code=429)
    return await call_next(request)


@app.middleware("http")
async def absolutize_media_urls_middleware(request: Request, call_next):
    """Phone clients can't load relative /media-files paths — pin to this request's origin.

    Must run *outside* GZipMiddleware: browsers send Accept-Encoding: gzip, so the
    JSON body is often compressed by the time we see it. Decompress → rewrite →
    return plain JSON (Cloudflare / browsers still accept uncompressed).
    """
    response = await call_next(request)
    if request.method == "OPTIONS" or request.url.path.startswith("/media-files"):
        return response
    ctype = (response.headers.get("content-type") or "").lower()
    if "application/json" not in ctype:
        return response
    body = b""
    async for chunk in response.body_iterator:
        body += chunk if isinstance(chunk, (bytes, bytearray)) else bytes(chunk)
    if not body:
        return Response(
            content=body,
            status_code=response.status_code,
            headers={
                k: v
                for k, v in response.headers.items()
                if k.lower() not in {"content-length"}
            },
            media_type=ctype.split(";")[0] or "application/json",
            background=response.background,
        )
    try:
        import gzip
        import json
        import logging

        raw = body
        encoding = (response.headers.get("content-encoding") or "").strip().lower()
        if encoding == "gzip":
            raw = gzip.decompress(body)
        data = json.loads(raw)
        origin = public_origin(request)
        rewritten = rewrite_media_tree(data, origin)
        new_body = json.dumps(rewritten, default=str).encode("utf-8")
    except Exception:
        logging.getLogger(__name__).exception(
            "media URL rewrite failed path=%s host=%s xfh=%s",
            request.url.path,
            request.headers.get("host"),
            request.headers.get("x-forwarded-host"),
        )
        new_body = body
        # Keep original encoding if we failed mid-flight.
        headers = {
            k: v
            for k, v in response.headers.items()
            if k.lower() not in {"content-length"}
        }
        return Response(
            content=new_body,
            status_code=response.status_code,
            headers=headers,
            media_type=ctype.split(";")[0] or "application/json",
            background=response.background,
        )

    headers = {
        k: v
        for k, v in response.headers.items()
        if k.lower() not in {"content-length", "content-type", "content-encoding"}
    }
    return Response(
        content=new_body,
        status_code=response.status_code,
        headers=headers,
        media_type="application/json",
        background=response.background,
    )


app.include_router(api_router)


@app.get("/health")
async def health_alias():
    return {"status": "ok", "app": settings.app_name}


@app.get("/api")
async def api_root():
    return {
        "name": "WAMU",
        "tagline": "Connect. Discover. Do More.",
        "docs": "/docs",
        "health": "/api/v1/health",
    }


@app.get("/connect")
async def connect_page(request: Request):
    """Phone setup page with QR — scan from the Wamu app to link this server."""
    origin = public_origin(request)
    api = f"{origin}/api/v1"
    template = Path(__file__).resolve().parent / "templates" / "connect.html"
    if template.is_file():
        html = template.read_text(encoding="utf-8").replace("__API__", api)
    else:
        html = f"""<!DOCTYPE html><html><body>
        <h1>Wamu</h1><p>Link URL:</p><code>{api}</code>
        <p>Open Wamu → Link device → paste this URL.</p>
        </body></html>"""
    return HTMLResponse(html)


@app.get("/link")
async def account_link_page():
    """Camera-app landing if someone scans the account QR outside Wamu."""
    template = Path(__file__).resolve().parent / "templates" / "link.html"
    if template.is_file():
        return HTMLResponse(template.read_text(encoding="utf-8"))
    return HTMLResponse(
        "<html><body><h1>Wamu</h1><p>Open the Wamu app and scan this code to sign in.</p></body></html>"
    )


@app.get("/connect.json")
async def connect_json(request: Request):
    origin = public_origin(request)
    return {"api_base_url": f"{origin}/api/v1", "origin": origin}


# Phone demo: serve Flutter web at / so one tunnel URL is API + UI (refresh = new UI).
if _WEB_ROOT.is_dir() and (_WEB_ROOT / "index.html").is_file():
    app.mount(
        "/",
        StaticFiles(directory=str(_WEB_ROOT), html=True),
        name="flutter-web",
    )
else:

    @app.get("/")
    async def root():
        return {
            "name": "WAMU",
            "tagline": "Connect. Discover. Do More.",
            "docs": "/docs",
            "health": "/api/v1/health",
            "connect": "/connect",
            "hint": "Open /connect on the phone to copy the API URL into the APK",
        }
