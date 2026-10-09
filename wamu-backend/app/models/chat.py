"""Chat: conversations, members, messages (realtime fan-out via Redis pub/sub when enabled)."""

from __future__ import annotations

import enum
import uuid
from datetime import datetime

from sqlalchemy import Boolean, DateTime, ForeignKey, Integer, String, Text, UniqueConstraint, func
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.core.database import Base
from app.models.mixins import TimestampMixin, UUIDMixin


class ConversationType(str, enum.Enum):
    CUSTOMER_BUSINESS = "CUSTOMER_BUSINESS"
    DIRECT = "DIRECT"
    GROUP = "GROUP"


class MessageType(str, enum.Enum):
    TEXT = "TEXT"
    IMAGE = "IMAGE"
    VOICE = "VOICE"
    DOCUMENT = "DOCUMENT"
    SYSTEM = "SYSTEM"
    ORDER_CARD = "ORDER_CARD"


class Conversation(UUIDMixin, TimestampMixin, Base):
    __tablename__ = "conversations"

    type: Mapped[str] = mapped_column(
        String(30), nullable=False, default=ConversationType.CUSTOMER_BUSINESS.value
    )
    business_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True), ForeignKey("businesses.id"), nullable=True, index=True
    )
    # GROUP title + optional curated community slug (kampala-campus, …)
    title: Mapped[str | None] = mapped_column(String(200))
    community_slug: Mapped[str | None] = mapped_column(String(80), index=True)
    last_message_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))

    members: Mapped[list[ConversationMember]] = relationship(
        "ConversationMember", back_populates="conversation", cascade="all, delete-orphan"
    )
    messages: Mapped[list[Message]] = relationship(
        "Message", back_populates="conversation", cascade="all, delete-orphan"
    )


class ConversationMember(UUIDMixin, Base):
    __tablename__ = "conversation_members"
    __table_args__ = (
        UniqueConstraint("conversation_id", "user_id", name="uq_conversation_member"),
    )

    conversation_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("conversations.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True
    )
    unread_count: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    joined_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )
    muted: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)
    pinned: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)
    archived: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)
    favourite: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)
    # Local inbox hide — peer history is unchanged; no delete alert.
    hidden_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    # ADMIN | MEMBER — group/community moderation
    member_role: Mapped[str] = mapped_column(String(20), nullable=False, default="MEMBER")

    conversation: Mapped[Conversation] = relationship("Conversation", back_populates="members")


class Message(UUIDMixin, Base):
    __tablename__ = "messages"
    __table_args__ = (
        UniqueConstraint(
            "conversation_id",
            "sender_id",
            "client_message_id",
            name="uq_message_client_id",
        ),
    )

    conversation_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("conversations.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    sender_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id"), nullable=False, index=True
    )
    body: Mapped[str] = mapped_column(Text, nullable=False)
    message_type: Mapped[str] = mapped_column(
        String(20), nullable=False, default=MessageType.TEXT.value
    )
    media_url: Mapped[str | None] = mapped_column(Text)
    # Client outbox id — retries with the same id must not create duplicates
    client_message_id: Mapped[str | None] = mapped_column(String(80), nullable=True, index=True)
    # Delivery status for the recipient side (sent/delivered/read simplified)
    status: Mapped[str] = mapped_column(String(20), nullable=False, default="SENT")
    reply_to_message_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("messages.id", ondelete="SET NULL"),
        nullable=True,
        index=True,
    )
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False, index=True
    )
    deleted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))

    conversation: Mapped[Conversation] = relationship("Conversation", back_populates="messages")
    reactions: Mapped[list[MessageReaction]] = relationship(
        "MessageReaction", back_populates="message", cascade="all, delete-orphan"
    )
    reply_to: Mapped[Message | None] = relationship(
        "Message",
        remote_side="Message.id",
        foreign_keys=[reply_to_message_id],
    )


class MessageReaction(UUIDMixin, Base):
    """Emoji reactions — youth engagement without full message edit stack."""

    __tablename__ = "message_reactions"
    __table_args__ = (
        UniqueConstraint("message_id", "user_id", "emoji", name="uq_message_reaction"),
    )

    message_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("messages.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True
    )
    emoji: Mapped[str] = mapped_column(String(16), nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )

    message: Mapped[Message] = relationship("Message", back_populates="reactions")


class MessageHide(UUIDMixin, Base):
    """Per-user hide — delete-for-me. Message stays for other members."""

    __tablename__ = "message_hides"
    __table_args__ = (UniqueConstraint("message_id", "user_id", name="uq_message_hide_user"),)

    message_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("messages.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True
    )
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )
