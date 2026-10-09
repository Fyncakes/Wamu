"""Bootstrap DB schema + MVP seed (Master Plan v3 — no theatrical demos).

Seeds only what Phase 0 / commerce MVP needs:
  - Categories (Kampala food & groceries beachhead + expansion)
  - Platform admin account

Does NOT seed Demo Spec personas (Sarah / Mama Grace / Ronald),
social DMs, campus groups, or passenger rides.

When the discover feed is empty and seed MP4s exist under media_uploads/seed/,
non-production bootstrap attaches those clips to existing shops (no new personas).
"""

from __future__ import annotations

import asyncio
import logging

from sqlalchemy import select

from app.core.database import AsyncSessionLocal, Base, engine
from app.models import *  # noqa: F401,F403
from app.models.business import Category
from app.models.user import User, UserProfile, UserRole
from app.services.utils import slugify

logger = logging.getLogger(__name__)

# Kampala beachhead first (food/groceries), then broader categories for growth.
CATEGORIES = [
    "Restaurants",
    "Groceries",
    "Cakes & Bakery",
    "Fashion",
    "Beauty",
    "Electronics",
    "Phones & Accessories",
    "Home Services",
    "Construction",
    "Automotive",
    "Education",
    "Health",
    "Events",
    "Entertainment",
    "Professional Services",
]

ADMIN_PHONE = "+256700000001"


def _ensure_sqlite_columns(sync_conn) -> None:
    """SQLite create_all does not add new columns — patch messaging schema."""
    if sync_conn.dialect.name != "sqlite":
        return
    msg_cols = {r[1] for r in sync_conn.exec_driver_sql("PRAGMA table_info(messages)").fetchall()}
    if "media_url" not in msg_cols:
        sync_conn.exec_driver_sql("ALTER TABLE messages ADD COLUMN media_url TEXT")
        logger.info("Added messages.media_url column")
    if "reply_to_message_id" not in msg_cols:
        sync_conn.exec_driver_sql("ALTER TABLE messages ADD COLUMN reply_to_message_id TEXT")
        logger.info("Added messages.reply_to_message_id column")
    if "client_message_id" not in msg_cols:
        sync_conn.exec_driver_sql("ALTER TABLE messages ADD COLUMN client_message_id VARCHAR(80)")
        logger.info("Added messages.client_message_id column")

    convo_cols = {
        r[1] for r in sync_conn.exec_driver_sql("PRAGMA table_info(conversations)").fetchall()
    }
    if "title" not in convo_cols:
        sync_conn.exec_driver_sql("ALTER TABLE conversations ADD COLUMN title VARCHAR(200)")
        logger.info("Added conversations.title column")
    if "community_slug" not in convo_cols:
        sync_conn.exec_driver_sql(
            "ALTER TABLE conversations ADD COLUMN community_slug VARCHAR(80)"
        )
        logger.info("Added conversations.community_slug column")

    member_cols = {
        r[1] for r in sync_conn.exec_driver_sql("PRAGMA table_info(conversation_members)").fetchall()
    }
    for col in ("pinned", "archived", "favourite"):
        if col not in member_cols:
            sync_conn.exec_driver_sql(
                f"ALTER TABLE conversation_members ADD COLUMN {col} BOOLEAN DEFAULT 0 NOT NULL"
            )
            logger.info("Added conversation_members.%s column", col)
    if "member_role" not in member_cols:
        sync_conn.exec_driver_sql(
            "ALTER TABLE conversation_members ADD COLUMN member_role VARCHAR(20) DEFAULT 'MEMBER' NOT NULL"
        )
        logger.info("Added conversation_members.member_role column")

    try:
        status_cols = {
            r[1] for r in sync_conn.exec_driver_sql("PRAGMA table_info(status_updates)").fetchall()
        }
        if "audience" not in status_cols:
            sync_conn.exec_driver_sql(
                "ALTER TABLE status_updates ADD COLUMN audience VARCHAR(20) DEFAULT 'CONTACTS' NOT NULL"
            )
            logger.info("Added status_updates.audience column")
    except Exception:
        pass

    user_cols = {r[1] for r in sync_conn.exec_driver_sql("PRAGMA table_info(users)").fetchall()}
    if "last_seen_at" not in user_cols:
        sync_conn.exec_driver_sql("ALTER TABLE users ADD COLUMN last_seen_at DATETIME")
        logger.info("Added users.last_seen_at column")

    biz_cols = {
        r[1] for r in sync_conn.exec_driver_sql("PRAGMA table_info(businesses)").fetchall()
    }
    if "payout_phone" not in biz_cols:
        sync_conn.exec_driver_sql("ALTER TABLE businesses ADD COLUMN payout_phone VARCHAR(20)")
        logger.info("Added businesses.payout_phone column")
    if "payout_provider" not in biz_cols:
        sync_conn.exec_driver_sql("ALTER TABLE businesses ADD COLUMN payout_provider VARCHAR(20)")
        logger.info("Added businesses.payout_provider column")

    profile_cols = {
        r[1] for r in sync_conn.exec_driver_sql("PRAGMA table_info(user_profiles)").fetchall()
    }
    if "show_last_seen" not in profile_cols:
        sync_conn.exec_driver_sql(
            "ALTER TABLE user_profiles ADD COLUMN show_last_seen BOOLEAN DEFAULT 1 NOT NULL"
        )
        logger.info("Added user_profiles.show_last_seen column")
    if "show_online" not in profile_cols:
        sync_conn.exec_driver_sql(
            "ALTER TABLE user_profiles ADD COLUMN show_online BOOLEAN DEFAULT 1 NOT NULL"
        )
        logger.info("Added user_profiles.show_online column")
    if "show_read_receipts" not in profile_cols:
        sync_conn.exec_driver_sql(
            "ALTER TABLE user_profiles ADD COLUMN show_read_receipts BOOLEAN DEFAULT 1 NOT NULL"
        )
        logger.info("Added user_profiles.show_read_receipts column")
    if "wants_to_buy" not in profile_cols:
        sync_conn.exec_driver_sql(
            "ALTER TABLE user_profiles ADD COLUMN wants_to_buy BOOLEAN DEFAULT 1 NOT NULL"
        )
        logger.info("Added user_profiles.wants_to_buy column")
    if "owns_business" not in profile_cols:
        sync_conn.exec_driver_sql(
            "ALTER TABLE user_profiles ADD COLUMN owns_business BOOLEAN DEFAULT 0 NOT NULL"
        )
        logger.info("Added user_profiles.owns_business column")
    if "wants_to_ride" not in profile_cols:
        sync_conn.exec_driver_sql(
            "ALTER TABLE user_profiles ADD COLUMN wants_to_ride BOOLEAN DEFAULT 0 NOT NULL"
        )
        logger.info("Added user_profiles.wants_to_ride column")

    try:
        payout_cols = {
            r[1]
            for r in sync_conn.exec_driver_sql("PRAGMA table_info(merchant_payouts)").fetchall()
        }
    except Exception:
        payout_cols = set()
    if payout_cols:
        if "platform_fee" not in payout_cols:
            sync_conn.exec_driver_sql(
                "ALTER TABLE merchant_payouts ADD COLUMN platform_fee NUMERIC DEFAULT 0 NOT NULL"
            )
            logger.info("Added merchant_payouts.platform_fee column")
        if "fee_bps" not in payout_cols:
            sync_conn.exec_driver_sql(
                "ALTER TABLE merchant_payouts ADD COLUMN fee_bps INTEGER DEFAULT 0 NOT NULL"
            )
            logger.info("Added merchant_payouts.fee_bps column")

    try:
        review_cols = {
            r[1] for r in sync_conn.exec_driver_sql("PRAGMA table_info(reviews)").fetchall()
        }
    except Exception:
        review_cols = set()
    if review_cols:
        if "rider_id" not in review_cols:
            sync_conn.exec_driver_sql("ALTER TABLE reviews ADD COLUMN rider_id CHAR(32)")
            logger.info("Added reviews.rider_id column")
        if "rider_rating" not in review_cols:
            sync_conn.exec_driver_sql("ALTER TABLE reviews ADD COLUMN rider_rating INTEGER")
            logger.info("Added reviews.rider_rating column")

    # Rider KYC columns (create_all won't alter existing rider_profiles)
    try:
        rider_cols = {
            r[1] for r in sync_conn.exec_driver_sql("PRAGMA table_info(rider_profiles)").fetchall()
        }
    except Exception:
        rider_cols = set()
    if rider_cols:
        rider_patches = [
            ("date_of_birth", "DATE"),
            ("nin", "VARCHAR(40)"),
            ("emergency_contact_name", "VARCHAR(120)"),
            ("emergency_contact_phone", "VARCHAR(20)"),
            ("location_text", "VARCHAR(255)"),
            ("licence_number", "VARCHAR(60)"),
            ("licence_expiry", "DATE"),
            ("licence_class", "VARCHAR(40)"),
            ("motorcycle_reg", "VARCHAR(40)"),
            ("motorcycle_ownership", "VARCHAR(255)"),
            ("insurance_policy", "VARCHAR(80)"),
            ("insurance_reg", "VARCHAR(40)"),
            ("insurance_valid_from", "DATE"),
            ("insurance_valid_to", "DATE"),
            ("ai_result", "VARCHAR(20)"),
            ("ai_checks", "JSON"),
            ("ai_ran_at", "DATETIME"),
            ("admin_note", "TEXT"),
            ("rejection_reason", "TEXT"),
            ("reupload_fields", "JSON"),
            ("submitted_at", "DATETIME"),
            ("reviewed_at", "DATETIME"),
            ("reviewed_by_id", "CHAR(32)"),
        ]
        for col, typ in rider_patches:
            if col not in rider_cols:
                sync_conn.exec_driver_sql(f"ALTER TABLE rider_profiles ADD COLUMN {col} {typ}")
                logger.info("Added rider_profiles.%s column", col)

    try:
        member_cols = {
            r[1]
            for r in sync_conn.exec_driver_sql("PRAGMA table_info(conversation_members)").fetchall()
        }
    except Exception:
        member_cols = set()
    if member_cols and "hidden_at" not in member_cols:
        sync_conn.exec_driver_sql(
            "ALTER TABLE conversation_members ADD COLUMN hidden_at DATETIME"
        )
        logger.info("Added conversation_members.hidden_at column")


async def bootstrap() -> None:
    """
    Local/dev: ensure schema via create_all + SQLite patches, then MVP seed.
    Production/staging: prefer `alembic upgrade head` in deploy; create_all here
    remains a safety net for empty DBs but is not the migration source of truth.
    """
    from app.core.config import get_settings

    settings = get_settings()
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
        await conn.run_sync(_ensure_sqlite_columns)
    if settings.is_production:
        logger.warning(
            "Production boot used create_all safety net — ensure deploy ran "
            "`alembic upgrade head` before traffic"
        )
    logger.info("Schema ensured (env=%s)", settings.environment)

    async with AsyncSessionLocal() as db:
        existing = await db.scalar(select(Category).limit(1))
        if not existing:
            await _seed_mvp_foundation(db)
            await db.commit()
            logger.info("Seeded categories + admin + demo personas")
        else:
            logger.info("Categories present — ensuring admin (no demo personas)")
            await _ensure_admin(db)
            await _retire_demo_personas(db)
            await db.commit()

    # Video-home needs clips when shops exist (dev only; idempotent).
    try:
        from scripts.seed_discover_videos import seed_discover_videos

        n = await seed_discover_videos()
        if n:
            logger.info("Attached %s seed clips to discover feed", n)
    except Exception:
        logger.exception("Discover video seed skipped")

    try:
        from scripts.seed_demo_images import seed_demo_images

        n = await seed_demo_images()
        if n:
            logger.info("Attached demo shop/product imagery for %s shops", n)
    except Exception:
        logger.exception("Demo image seed skipped")


async def _ensure_admin(db) -> None:
    admin = await db.scalar(select(User).where(User.phone == ADMIN_PHONE))
    if admin:
        return
    admin = User(
        phone=ADMIN_PHONE,
        phone_verified=True,
        role=UserRole.ADMIN.value,
    )
    db.add(admin)
    await db.flush()
    db.add(
        UserProfile(
            user_id=admin.id,
            first_name="Wamu",
            last_name="Admin",
            username="wamuadmin",
        )
    )
    logger.info("Ensured platform admin %s", ADMIN_PHONE)


# Phone-chip demos used during internal testing — retire for real-user trials.
_DEMO_PHONES = (
    "+256700000099",  # customer
    "+256700000088",  # merchant
    "+256700000077",  # rider
    "+256700000101",
    "+256700000102",
    "+256700000103",
    "+256700000104",
)


async def _retire_demo_personas(db) -> None:
    """Suspend seeded demo accounts so only real testers + admin can sign in."""
    from app.models.user import UserStatus

    users = (
        await db.scalars(select(User).where(User.phone.in_(_DEMO_PHONES)))
    ).all()
    n = 0
    for u in users:
        if u.phone == ADMIN_PHONE:
            continue
        if u.status != UserStatus.SUSPENDED.value:
            u.status = UserStatus.SUSPENDED.value
            n += 1
    if n:
        logger.info("Suspended %s demo persona account(s) for real-user testing", n)


async def _ensure_demo_personas(db) -> None:
    """Legacy seed kept for optional local fixtures — not called on boot anymore.

    Phones:
      +256700000099 customer
      +256700000088 merchant (owns a verified shop)
      +256700000077 rider (APPROVED)
    OTP mock code 123456. Admin remains +256700000001 (web only).
    """
    from decimal import Decimal

    from app.models.business import (
        Business,
        BusinessMember,
        BusinessStatus,
        Location,
        MemberRole,
        VerificationStatus,
    )
    from app.models.rider import RiderProfile, RiderStatus

    async def ensure_user(
        phone: str,
        *,
        first: str,
        last: str,
        role: str = UserRole.CUSTOMER.value,
        owns_business: bool = False,
        wants_to_ride: bool = False,
    ) -> User:
        user = await db.scalar(select(User).where(User.phone == phone))
        if not user:
            user = User(phone=phone, phone_verified=True, role=role)
            db.add(user)
            await db.flush()
            db.add(
                UserProfile(
                    user_id=user.id,
                    first_name=first,
                    last_name=last,
                    owns_business=owns_business,
                    wants_to_buy=True,
                    wants_to_ride=wants_to_ride,
                )
            )
            await db.flush()
            logger.info("Seeded demo user %s (%s)", phone, first)
            return user

        profile = await db.scalar(select(UserProfile).where(UserProfile.user_id == user.id))
        if profile is None:
            db.add(
                UserProfile(
                    user_id=user.id,
                    first_name=first,
                    last_name=last,
                    owns_business=owns_business,
                    wants_to_buy=True,
                    wants_to_ride=wants_to_ride,
                )
            )
            await db.flush()
        else:
            if owns_business:
                profile.owns_business = True
            if wants_to_ride:
                profile.wants_to_ride = True
        return user

    await ensure_user("+256700000099", first="Demo", last="Customer")
    merchant = await ensure_user(
        "+256700000088",
        first="Demo",
        last="Merchant",
        owns_business=True,
    )
    rider_user = await ensure_user(
        "+256700000077",
        first="Demo",
        last="Rider",
        wants_to_ride=True,
    )

    cat = await db.scalar(select(Category).limit(1))
    existing_biz = await db.scalar(
        select(Business).where(Business.owner_id == merchant.id, Business.deleted_at.is_(None))
    )
    if not existing_biz and cat:
        biz = Business(
            owner_id=merchant.id,
            name="Demo Merchant Kitchen",
            slug=slugify(f"demo-merchant-{str(merchant.id)[:8]}"),
            description="Seed shop for phone demos — check Sales report after orders.",
            phone="+256700000088",
            payout_phone="+256700000088",
            payout_provider="MTN",
            category_id=cat.id,
            status=BusinessStatus.ACTIVE.value,
            verification_status=VerificationStatus.VERIFIED.value,
        )
        db.add(biz)
        await db.flush()
        db.add(
            BusinessMember(
                business_id=biz.id,
                user_id=merchant.id,
                role=MemberRole.OWNER.value,
                is_active=True,
            )
        )
        db.add(
            Location(
                business_id=biz.id,
                address_line="Ntinda Shopping Centre",
                city="Kampala",
                latitude=Decimal("0.3476000"),
                longitude=Decimal("32.6305000"),
            )
        )
        logger.info("Seeded demo merchant shop for %s", merchant.phone)

    rider = await db.scalar(
        select(RiderProfile).where(
            RiderProfile.user_id == rider_user.id,
            RiderProfile.deleted_at.is_(None),
        )
    )
    if not rider:
        db.add(
            RiderProfile(
                user_id=rider_user.id,
                display_name="Demo Rider",
                wamu_rider_ref=f"WAMU-R-DEMO{str(rider_user.id).replace('-', '')[:6].upper()}",
                vehicle_type="BODA",
                plate_number="UBE 77D",
                status=RiderStatus.APPROVED.value,
                available_delivery=True,
                available_rides=True,
                lat=Decimal("0.3476000"),
                lng=Decimal("32.5825000"),
            )
        )
        logger.info("Seeded approved demo rider %s", rider_user.phone)
    elif rider.status != RiderStatus.APPROVED.value:
        rider.status = RiderStatus.APPROVED.value
        rider.available_delivery = True
        rider.available_rides = True

    # Demo products get bought down to 0 — keep a floor so phone checkout keeps working.
    await _restock_demo_inventory(db)


async def _restock_demo_inventory(db) -> None:
    from sqlalchemy import update

    from app.models.product import Product

    result = await db.execute(
        update(Product)
        .where(
            Product.deleted_at.is_(None),
            Product.stock_quantity.is_not(None),
            Product.stock_quantity < 20,
        )
        .values(stock_quantity=50)
    )
    if result.rowcount:
        logger.info("Restocked %s demo products below 20 units → 50", result.rowcount)


async def _seed_mvp_foundation(db) -> None:
    """Categories + admin only (real-user testing — no demo personas)."""
    for name in CATEGORIES:
        db.add(Category(name=name, slug=slugify(name), description=f"{name} in Uganda"))
    await db.flush()
    await _ensure_admin(db)


def main() -> None:
    logging.basicConfig(level=logging.INFO)
    asyncio.run(bootstrap())


if __name__ == "__main__":
    main()
