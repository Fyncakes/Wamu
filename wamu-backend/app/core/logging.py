"""Structured logging + request correlation for WAMU API."""

from __future__ import annotations

import logging
import sys
import uuid
from contextvars import ContextVar

request_id_ctx: ContextVar[str] = ContextVar("request_id", default="-")


class RequestIdFilter(logging.Filter):
    def filter(self, record: logging.LogRecord) -> bool:
        record.request_id = request_id_ctx.get()  # type: ignore[attr-defined]
        return True


def setup_logging(debug: bool = False) -> None:
    level = logging.DEBUG if debug else logging.INFO
    root = logging.getLogger()
    root.handlers.clear()
    handler = logging.StreamHandler(sys.stdout)
    handler.setLevel(level)
    handler.addFilter(RequestIdFilter())
    handler.setFormatter(
        logging.Formatter(
            "%(asctime)s | %(levelname)s | %(request_id)s | %(name)s | %(message)s"
        )
    )
    root.addHandler(handler)
    root.setLevel(level)

    # Never echo SQL binds / driver chatter — they include phones, emails, tokens.
    for noisy in (
        "sqlalchemy.engine",
        "sqlalchemy.engine.Engine",
        "sqlalchemy.pool",
        "sqlalchemy.dialects",
        "aiosqlite",
        "httpx",
        "httpcore",
        "asyncio",
    ):
        log = logging.getLogger(noisy)
        log.setLevel(logging.WARNING)
        log.propagate = True
        # Drop handlers SQLAlchemy may attach when echo=True historically.
        log.handlers.clear()


def new_request_id() -> str:
    return uuid.uuid4().hex[:16]
