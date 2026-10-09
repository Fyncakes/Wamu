#!/usr/bin/env python3
"""
Detect a LAN IP and print TURN_* lines for infrastructure/.env.staging.

Usage (from repo root or wamu-backend):
  python -m scripts.print_turn_env
  python -m scripts.print_turn_env --ip 192.168.1.42
"""

from __future__ import annotations

import argparse
import socket
import sys


def detect_lan_ip() -> str:
    """Best-effort primary LAN address (no packets sent beyond UDP connect)."""
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.connect(("8.8.8.8", 80))
        ip = sock.getsockname()[0]
        sock.close()
        if ip and not ip.startswith("127."):
            return ip
    except OSError:
        pass
    hostname = socket.gethostname()
    try:
        for info in socket.getaddrinfo(hostname, None, socket.AF_INET):
            cand = info[4][0]
            if cand and not cand.startswith("127."):
                return cand
    except OSError:
        pass
    return "127.0.0.1"


def main() -> int:
    parser = argparse.ArgumentParser(description="Print Wamu TURN env for staging")
    parser.add_argument("--ip", help="Override detected LAN / public IP")
    parser.add_argument(
        "--username",
        default="wamu",
        help="TURN_USERNAME (must match coturn --user)",
    )
    parser.add_argument(
        "--credential",
        default="staging-turn-change-me",
        help="TURN_CREDENTIAL (must match coturn --user)",
    )
    args = parser.parse_args()
    ip = (args.ip or detect_lan_ip()).strip()
    if ip.startswith("127.") or ip == "localhost":
        print(
            "# WARNING: detected loopback — phones on MTN/Airtel cannot reach this.\n"
            "# Pass --ip <LAN-or-public-IP> of the machine running coturn.",
            file=sys.stderr,
        )

    urls = (
        f"turn:{ip}:3478?transport=udp,"
        f"turn:{ip}:3478?transport=tcp"
    )
    block = "\n".join(
        [
            f"# Paste into infrastructure/.env.staging then:",
            f"#   docker compose -f infrastructure/docker-compose.staging.yml \\",
            f"#     --env-file infrastructure/.env.staging --profile turn up -d",
            f"TURN_EXTERNAL_IP={ip}",
            f"TURN_URLS={urls}",
            f"TURN_USERNAME={args.username}",
            f"TURN_CREDENTIAL={args.credential}",
            "",
        ]
    )
    print(block)
    return 0 if not ip.startswith("127.") else 2


if __name__ == "__main__":
    raise SystemExit(main())
