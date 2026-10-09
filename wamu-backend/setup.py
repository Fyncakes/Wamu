"""
WAMU Backend — FastAPI application for the Uganda Super App MVP.

Stack: FastAPI + SQLAlchemy 2 (async) + PostgreSQL + Redis + Celery.
Never trust the mobile client for prices, ownership, or roles — enforce server-side.
"""

from pathlib import Path

from setuptools import find_packages, setup

ROOT = Path(__file__).parent
readme = (ROOT / "README.md").read_text(encoding="utf-8") if (ROOT / "README.md").exists() else "WAMU Backend"

setup(
    name="wamu-backend",
    version="0.1.0",
    description="WAMU Uganda Super App API",
    long_description=readme,
    packages=find_packages(),
    python_requires=">=3.12",
    install_requires=[
        "fastapi>=0.115.0",
        "uvicorn[standard]>=0.32.0",
        "sqlalchemy[asyncio]>=2.0.36",
        "asyncpg>=0.30.0",
        "alembic>=1.14.0",
        "pydantic[email]>=2.10.0",
        "pydantic-settings>=2.6.0",
        "PyJWT>=2.10.0",
        "passlib[argon2]>=1.7.4",
        "argon2-cffi>=23.1.0",
        "redis>=5.2.0",
        "celery>=5.4.0",
        "boto3>=1.35.0",
        "httpx>=0.28.0",
        "python-multipart>=0.0.17",
        "orjson>=3.10.0",
        "email-validator>=2.2.0",
    ],
    extras_require={
        "dev": [
            "pytest>=8.3.0",
            "pytest-asyncio>=0.24.0",
            "httpx>=0.28.0",
            "ruff>=0.8.0",
            "aiosqlite>=0.20.0",
        ]
    },
)
