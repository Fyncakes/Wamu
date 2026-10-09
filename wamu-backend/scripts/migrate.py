#!/usr/bin/env python3
"""Run Alembic migrations to head (used by entrypoint + local ops)."""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def main() -> int:
    cmd = [sys.executable, "-m", "alembic", "upgrade", "head"]
    print("→", " ".join(cmd), flush=True)
    return subprocess.call(cmd, cwd=ROOT)


if __name__ == "__main__":
    raise SystemExit(main())
