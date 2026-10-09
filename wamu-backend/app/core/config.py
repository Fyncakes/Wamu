"""
Application settings — loaded from environment / .env.

NOTE: Never commit real SECRET_KEY or provider credentials.
Templates: .env.example (dev) · .env.production.example (prod checklist)
"""

from __future__ import annotations

from functools import lru_cache
from typing import List

from pydantic import Field, field_validator, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


_WEAK_SECRETS = {
    "change-me-in-production-use-long-random-string",
    "change-me",
    "secret",
    "dev-only-change-me-use-32chars-min!!",
}


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore",
    )

    app_name: str = "WAMU"
    app_version: str = "1.0.0-mvp"
    environment: str = "development"  # development | staging | production
    debug: bool = True
    secret_key: str = "change-me-in-production-use-long-random-string"
    access_token_expire_minutes: int = 30
    refresh_token_expire_days: int = 30
    # Short-lived tickets for WebSocket handshake (avoid long JWT in URLs/logs)
    ws_ticket_expire_seconds: int = 60

    database_url: str = "postgresql+asyncpg://wamu:wamu@localhost:5432/wamu"
    redis_url: str = "redis://localhost:6379/0"
    celery_broker_url: str = "redis://localhost:6379/1"

    otp_expire_seconds: int = 300
    device_link_expire_seconds: int = 120
    otp_length: int = 6
    otp_mock_mode: bool = True
    otp_mock_code: str = "123456"
    # Africa's Talking — required when OTP_MOCK_MODE=false
    africastalking_username: str = ""
    africastalking_api_key: str = ""
    africastalking_sender_id: str = ""

    # Demo/default: local disk. Set S3_ENABLED=true when MinIO is up.
    s3_enabled: bool = False
    s3_endpoint_url: str = "http://localhost:9000"
    s3_public_url: str = "http://localhost:9000"
    s3_access_key: str = "wamuadmin"
    s3_secret_key: str = "wamusecret"
    s3_bucket: str = "wamu-media"
    s3_region: str = "us-east-1"

    cors_origins: List[str] = Field(
        default_factory=lambda: ["http://localhost:3000", "http://localhost:8080"]
    )
    rate_limit_otp_per_hour: int = 5
    rate_limit_api_per_minute: int = 120
    payment_mock_auto_success: bool = True
    # Platform fee in basis points on merchant payout (250 = 2.5%). Fee stays in
    # MoMo float — Wamu never holds a wallet balance. 0 = pay full collection.
    platform_fee_bps: int = 0
    # HMAC secret for POST /payments/webhooks/{provider} (X-Wamu-Signature / provider headers)
    payment_webhook_secret: str = "dev-webhook-secret-change-me"
    # MTN MoMo Collections (leave empty until staging credentials issued)
    mtn_subscription_key: str = ""
    mtn_api_user: str = ""
    mtn_api_key: str = ""
    mtn_webhook_secret: str = ""
    mtn_base_url: str = "https://sandbox.momodeveloper.mtn.com"
    mtn_target_environment: str = "sandbox"
    # Airtel Money
    airtel_client_id: str = ""
    airtel_client_secret: str = ""
    airtel_webhook_secret: str = ""
    airtel_base_url: str = "https://openapiuat.airtel.africa"
    admin_bootstrap_phone: str = "+256700000001"
    public_media_base: str = "http://127.0.0.1:8000"
    # Fan-out chat events via Redis when available (multi-instance safe)
    realtime_use_redis: bool = True
    # Optional FCM server key — empty = mock push (logs only)
    fcm_server_key: str = ""
    # Presence online TTL — must exceed mobile presence.ping (~40s)
    presence_ttl_seconds: int = 90
    # WebRTC ICE — STUN always; TURN optional for MTN/Airtel carrier NAT
    stun_urls: str = (
        "stun:stun.l.google.com:19302,stun:stun1.l.google.com:19302"
    )
    turn_urls: str = ""  # comma-separated turn:/turns: URIs
    turn_username: str = ""
    turn_credential: str = ""
    # Optional — leave empty in local/dev
    sentry_dsn: str = ""
    # Short-video delivery (ffmpeg). Empty = auto-detect bundled/.tools or PATH.
    ffmpeg_path: str = ""
    video_max_height: int = 720
    video_crf: int = 28
    # Soft defaults; Admin can override via app_settings table.
    video_archive_after_days: int = 180
    video_purge_after_days: int = 365
    # Prefer clips under this size in the Discover feed sort (bytes).
    video_feed_prefer_under_bytes: int = 4 * 1024 * 1024

    @field_validator("environment")
    @classmethod
    def _norm_env(cls, v: str) -> str:
        return (v or "development").strip().lower()

    @field_validator("cors_origins", mode="before")
    @classmethod
    def _parse_cors(cls, v):
        if isinstance(v, str):
            import json

            try:
                return json.loads(v)
            except Exception:
                return [x.strip() for x in v.split(",") if x.strip()]
        return v

    @model_validator(mode="after")
    def _guard_production(self) -> Settings:
        """Fail closed when ENVIRONMENT=production — never ship demo defaults."""
        if self.environment != "production":
            return self
        errors: list[str] = []
        if self.debug:
            errors.append("DEBUG must be false in production")
        if self.otp_mock_mode:
            errors.append("OTP_MOCK_MODE must be false in production")
        if self.payment_mock_auto_success:
            errors.append("PAYMENT_MOCK_AUTO_SUCCESS must be false in production")
        if self.secret_key in _WEAK_SECRETS or len(self.secret_key) < 32:
            errors.append("SECRET_KEY must be a strong random string (≥32 chars)")
        if "*" in self.cors_origins:
            errors.append("CORS_ORIGINS must not include '*' in production")
        if not self.cors_origins:
            errors.append("CORS_ORIGINS must list explicit origins in production")
        if (
            not self.payment_webhook_secret
            or self.payment_webhook_secret.startswith("dev-")
            or len(self.payment_webhook_secret) < 24
        ):
            errors.append("PAYMENT_WEBHOOK_SECRET must be set (≥24 chars) in production")
        if errors:
            raise ValueError(
                "Production config refused:\n- " + "\n- ".join(errors)
            )
        return self

    @property
    def is_production(self) -> bool:
        return self.environment == "production"

    @property
    def is_development(self) -> bool:
        return self.environment == "development"


@lru_cache
def get_settings() -> Settings:
    return Settings()


def validate_runtime_settings() -> None:
    """Call at app startup so misconfiguration fails loud."""
    get_settings()
