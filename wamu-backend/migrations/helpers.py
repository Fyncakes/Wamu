"""Idempotent Alembic helpers — safe when 0001 create_all already applied current models."""

from __future__ import annotations

from alembic import op
from sqlalchemy import inspect


def _insp():
    return inspect(op.get_bind())


def table_exists(name: str) -> bool:
    return name in _insp().get_table_names()


def column_exists(table: str, column: str) -> bool:
    if not table_exists(table):
        return False
    return any(c["name"] == column for c in _insp().get_columns(table))


def index_exists(table: str, name: str) -> bool:
    if not table_exists(table):
        return False
    return any(ix["name"] == name for ix in _insp().get_indexes(table))


def unique_constraint_exists(table: str, name: str) -> bool:
    if not table_exists(table):
        return False
    return any(uc["name"] == name for uc in _insp().get_unique_constraints(table))
