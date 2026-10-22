"""
Database engine and session factory (SQLAlchemy 2 async).

All request handlers should depend on get_db() and never hold sessions across awaits
without care — one session per request is the default pattern.
"""

from collections.abc import AsyncGenerator

from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine
from sqlalchemy.orm import DeclarativeBase

from app.core.config import get_settings

settings = get_settings()

# Never enable SQLAlchemy echo in demos — it floods logs with binds (phones, hashes).
# Opt in only with SQL_ECHO=true for local deep debugging.
engine = create_async_engine(
    settings.database_url,
    echo=bool(getattr(settings, "sql_echo", False)),
    pool_pre_ping=True,
)

# SQLite: WAL + busy timeout so concurrent phone demos don't lock each other out.
if settings.database_url.startswith("sqlite"):
    from sqlalchemy import event

    @event.listens_for(engine.sync_engine, "connect")
    def _sqlite_on_connect(dbapi_conn, _connection_record):  # type: ignore[no-untyped-def]
        cursor = dbapi_conn.cursor()
        cursor.execute("PRAGMA journal_mode=WAL")
        cursor.execute("PRAGMA busy_timeout=8000")
        cursor.execute("PRAGMA synchronous=NORMAL")
        cursor.close()

AsyncSessionLocal = async_sessionmaker(
    engine,
    class_=AsyncSession,
    expire_on_commit=False,
    autoflush=False,
)


class Base(DeclarativeBase):
    """Shared declarative base for all ORM models."""


async def get_db() -> AsyncGenerator[AsyncSession, None]:
    async with AsyncSessionLocal() as session:
        try:
            yield session
            await session.commit()
        except Exception:
            await session.rollback()
            raise
