#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import re
import sys
from datetime import datetime
from pathlib import Path
from typing import Any
from urllib.parse import urlparse


def main() -> int:
    parser = argparse.ArgumentParser(description="Graph KPI action helpers.")
    subparsers = parser.add_subparsers(dest="command", required=True)

    validate_url = subparsers.add_parser("validate-url")
    validate_url.add_argument("--url", required=True)
    validate_url.add_argument("--allowed-hosts", required=True)
    validate_url.add_argument("--base-url", action="store_true")

    validate_date = subparsers.add_parser("validate-date")
    validate_date.add_argument("snapshot_date")

    render_report = subparsers.add_parser("render-report")
    render_report.add_argument("--details-json", required=True)
    render_report.add_argument("--payload-json", required=True)
    render_report.add_argument("--report-md", required=True)

    args = parser.parse_args()
    try:
        if args.command == "validate-url":
            validate_url_is_allowed(args.url, args.allowed_hosts, base_url=args.base_url)
        elif args.command == "validate-date":
            validate_snapshot_date(args.snapshot_date)
        elif args.command == "render-report":
            render_report_file(
                Path(args.details_json),
                Path(args.payload_json),
                Path(args.report_md),
            )
    except Exception as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    return 0


def validate_url_is_allowed(url: str, allowed_hosts: str, *, base_url: bool) -> None:
    allowed = {host.strip().lower() for host in allowed_hosts.split(",") if host.strip()}
    if not allowed:
        raise ValueError("allowed host list must not be empty.")
    parsed = urlparse(url)
    if parsed.scheme != "https":
        raise ValueError(f"{url} must use https.")
    if parsed.username or parsed.password:
        raise ValueError(f"{url} must not include user info.")
    host = (parsed.hostname or "").lower()
    if host not in allowed:
        raise ValueError(f"{host or url} is not in graph_kpis_allowed_hosts.")
    if base_url and (
        parsed.path not in {"", "/"} or parsed.params or parsed.query or parsed.fragment
    ):
        raise ValueError(f"{url} must be an origin URL without path, params, query, or fragment.")


def validate_snapshot_date(snapshot_date: str) -> None:
    if not re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}", snapshot_date):
        raise ValueError("snapshot date must use YYYY-MM-DD.")
    try:
        parsed = datetime.strptime(snapshot_date, "%Y-%m-%d")
    except ValueError as exc:
        raise ValueError("snapshot date must be a valid calendar date.") from exc
    if parsed.strftime("%Y-%m-%d") != snapshot_date:
        raise ValueError("snapshot date must use YYYY-MM-DD.")


def _object(value: Any) -> dict[str, Any]:
    return value if isinstance(value, dict) else {}


def render_report_file(details_json: Path, payload_json: Path, report_md: Path) -> None:
    with details_json.open("r", encoding="utf-8") as f:
        details = json.load(f)
    with payload_json.open("r", encoding="utf-8") as f:
        payload = json.load(f)
    if not isinstance(details, dict):
        raise ValueError("details JSON root must be an object.")
    if not isinstance(payload, dict):
        raise ValueError("payload JSON root must be an object.")

    totals = _object(details.get("totals"))
    compliance = _object(details.get("schema_compliance"))
    rich = _object(details.get("rich_snippet_candidate_entities"))

    lines = [
        "## Graph KPI Report",
        "",
        f"- Snapshot date: `{payload.get('snapshot_date', '')}`",
        f"- Calculated at: `{payload.get('calculated_at', '')}`",
        f"- Snapshot origin: `{payload.get('snapshot_origin', '')}`",
        f"- Total triples: `{totals.get('total_triples', 0)}`",
        f"- Website URLs: `{totals.get('unique_urls_within_website_scope', 0)}`",
        f"- Rich snippet candidates: `{rich.get('total', 0)}`",
        f"- URLs checked for schema compliance: `{compliance.get('urls_checked', 0)}`",
        f"- URLs with schema errors: `{compliance.get('urls_with_errors', 0)}`",
        f"- URLs with schema warnings: `{compliance.get('urls_with_warnings', 0)}`",
        "",
    ]
    report_md.parent.mkdir(parents=True, exist_ok=True)
    report_md.write_text("\n".join(lines), encoding="utf-8")


if __name__ == "__main__":
    raise SystemExit(main())
