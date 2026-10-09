"""Redis + memory presence registry tests."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from unittest.mock import AsyncMock, patch
from uuid import uuid4

import pytest
import pytest_asyncio
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine
from sqlalchemy.orm import selectinload

from app.core.database import Base
from app.models.user import User, UserProfile, UserRole
from app.services import presence as presence_service

TEST_DB = "sqlite+aiosqlite:///:memory:"


@pytest_asyncio.fixture
async def db():
    engine = create_async_engine(TEST_DB, future=True)
    session_factory = async_sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
    async with session_factory() as session:
        yield session
    await engine.dispose()


@pytest.fixture(autouse=True)
def _clear_memory():
    presence_service.reset_memory_presence()
    yield
    presence_service.reset_memory_presence()


@pytest.mark.asyncio
async def test_memory_mark_online_offline():
    with patch("app.services.presence._redis_client", new=AsyncMock(return_value=None)):
        uid = str(uuid4())
        assert await presence_service.mark_online(uid) is True
        assert await presence_service.is_online(uid) is True
        assert await presence_service.mark_online(uid) is False  # second socket
        assert await presence_service.mark_offline(uid) is False  # still one left
        assert await presence_service.is_online(uid) is True
        assert await presence_service.mark_offline(uid) is True
        assert await presence_service.is_online(uid) is False


class _FakePipe:
    def __init__(self, store: dict, ttl_store: dict):
        self.store = store
        self.ttl_store = ttl_store
        self._ops: list = []

    def incr(self, key):
        self._ops.append(("incr", key))
        return self

    def expire(self, key, ttl):
        self._ops.append(("expire", key, ttl))
        return self

    async def execute(self):
        out = []
        for op in self._ops:
            if op[0] == "incr":
                key = op[1]
                self.store[key] = int(self.store.get(key, 0)) + 1
                out.append(self.store[key])
            elif op[0] == "expire":
                self.ttl_store[op[1]] = op[2]
                out.append(True)
        self._ops.clear()
        return out


class _FakeRedis:
    def __init__(self):
        self.store: dict[str, int] = {}
        self.ttl: dict[str, int] = {}

    def pipeline(self):
        return _FakePipe(self.store, self.ttl)

    async def decr(self, key):
        self.store[key] = int(self.store.get(key, 0)) - 1
        return self.store[key]

    async def delete(self, key):
        self.store.pop(key, None)
        self.ttl.pop(key, None)
        return 1

    async def expire(self, key, ttl):
        if key in self.store:
            self.ttl[key] = ttl
            return True
        return False

    async def get(self, key):
        v = self.store.get(key)
        return None if v is None else str(v)


@pytest.mark.asyncio
async def test_redis_mark_online_offline_and_refresh():
    fake = _FakeRedis()
    with patch("app.services.presence._redis_client", new=AsyncMock(return_value=fake)), patch(
        "app.services.presence._ttl", return_value=90
    ):
        uid = str(uuid4())
        key = f"{presence_service.PRESENCE_PREFIX}{uid}"
        assert await presence_service.mark_online(uid) is True
        assert fake.store[key] == 1
        assert fake.ttl[key] == 90
        assert await presence_service.mark_online(uid) is False
        assert fake.store[key] == 2
        assert await presence_service.is_online(uid) is True

        assert await presence_service.mark_offline(uid) is False
        assert fake.store[key] == 1
        assert await presence_service.mark_offline(uid) is True
        assert key not in fake.store

        await presence_service.mark_online(uid)
        fake.ttl[key] = 1
        await presence_service.refresh_presence(uid)
        assert fake.ttl[key] == 90


@pytest.mark.asyncio
async def test_public_presence_respects_privacy(db: AsyncSession):
    user = User(
        phone=f"+2567{uuid4().hex[:8]}",
        phone_verified=True,
        role=UserRole.CUSTOMER.value,
        last_seen_at=datetime.now(timezone.utc) - timedelta(minutes=5),
    )
    db.add(user)
    await db.flush()
    db.add(
        UserProfile(
            user_id=user.id,
            first_name="A",
            show_online=False,
            show_last_seen=False,
        )
    )
    await db.commit()

    with patch("app.services.presence._redis_client", new=AsyncMock(return_value=None)):
        await presence_service.mark_online(user.id)
        from sqlalchemy import select

        peer = await db.scalar(
            select(User).options(selectinload(User.profile)).where(User.id == user.id)
        )
        vis = await presence_service.public_presence(peer)
        assert vis["peer_online"] is False
        assert vis["peer_last_seen_at"] is None


@pytest.mark.asyncio
async def test_presence_reciprocity_hides_peer_from_viewer(db: AsyncSession):
    """Viewer who hid last-seen/online must not see peer's shared presence."""
    from sqlalchemy import select

    peer = User(
        phone=f"+2567{uuid4().hex[:8]}",
        phone_verified=True,
        role=UserRole.CUSTOMER.value,
        last_seen_at=datetime.now(timezone.utc) - timedelta(minutes=2),
    )
    viewer = User(
        phone=f"+2567{uuid4().hex[:8]}",
        phone_verified=True,
        role=UserRole.CUSTOMER.value,
    )
    db.add_all([peer, viewer])
    await db.flush()
    db.add(
        UserProfile(
            user_id=peer.id,
            first_name="Peer",
            show_online=True,
            show_last_seen=True,
        )
    )
    db.add(
        UserProfile(
            user_id=viewer.id,
            first_name="Viewer",
            show_online=False,
            show_last_seen=False,
        )
    )
    await db.commit()

    with patch("app.services.presence._redis_client", new=AsyncMock(return_value=None)):
        await presence_service.mark_online(peer.id)
        peer_row = await db.scalar(
            select(User).options(selectinload(User.profile)).where(User.id == peer.id)
        )
        viewer_row = await db.scalar(
            select(User).options(selectinload(User.profile)).where(User.id == viewer.id)
        )
        without_viewer = await presence_service.public_presence(peer_row)
        assert without_viewer["peer_online"] is True
        assert without_viewer["peer_last_seen_at"] is not None

        with_viewer = await presence_service.public_presence(
            peer_row, viewer=viewer_row
        )
        assert with_viewer["peer_online"] is False
        assert with_viewer["peer_last_seen_at"] is None


@pytest.mark.asyncio
async def test_touch_last_seen(db: AsyncSession):
    user = User(
        phone=f"+2567{uuid4().hex[:8]}",
        phone_verified=True,
        role=UserRole.CUSTOMER.value,
    )
    db.add(user)
    await db.flush()
    before = user.last_seen_at
    now = await presence_service.touch_last_seen(db, user.id)
    await db.commit()
    assert user.last_seen_at == now
    assert user.last_seen_at != before
