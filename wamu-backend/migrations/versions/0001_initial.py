"""Initial schema — baseline bootstrap via SQLAlchemy metadata.create_all.

Greenfield installs run this once. All *subsequent* changes belong in
numbered revisions (0002, 0003, …) with explicit Alembic ops.
"""

from __future__ import annotations

from alembic import op

revision = "0001_initial"
down_revision = None
branch_labels = None
depends_on = None


def upgrade() -> None:
    from app.core.database import Base
    import app.models  # noqa: F401

    bind = op.get_bind()
    Base.metadata.create_all(bind=bind)


def downgrade() -> None:
    from app.core.database import Base
    import app.models  # noqa: F401

    bind = op.get_bind()
    Base.metadata.drop_all(bind=bind)
