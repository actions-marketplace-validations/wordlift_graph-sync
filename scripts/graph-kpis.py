#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import math
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

try:
    import tomllib
except ModuleNotFoundError:  # pragma: no cover - depends on runner Python
    try:
        import tomli as tomllib  # type: ignore[no-redef]
    except ModuleNotFoundError:  # pragma: no cover - depends on runner Python
        tomllib = None  # type: ignore[assignment]


FORBIDDEN_BODY_FIELDS = {
    "account_id",
    "graph_id",
    "dataset_id",
    "cloned_from_snapshot_date",
    "source_watermark",
    "kpi_worker_version",
    "validation_rules_fingerprint",
    "validated_at",
}

KNOWN_METADATA_FIELDS = {"snapshot_date", "calculated_at", "snapshot_origin"}
ENV_PATTERN = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Graph KPI action helpers.")
    subparsers = parser.add_subparsers(dest="command", required=True)

    resolve_key = subparsers.add_parser("resolve-key")
    resolve_key.add_argument("--profile", required=True)
    resolve_key.add_argument("--config-path", default="")
    resolve_key.add_argument("--working-directory", default=".")

    account_id = subparsers.add_parser("account-id")
    account_id.add_argument("account_json")

    validate_url = subparsers.add_parser("validate-url")
    validate_url.add_argument("--url", required=True)
    validate_url.add_argument("--allowed-hosts", required=True)
    validate_url.add_argument("--base-url", action="store_true")

    validate_date = subparsers.add_parser("validate-date")
    validate_date.add_argument("snapshot_date")

    build_payload = subparsers.add_parser("build-payload")
    build_payload.add_argument("--audit-json", required=True)
    build_payload.add_argument("--payload-json", required=True)
    build_payload.add_argument("--report-md", required=True)
    build_payload.add_argument("--snapshot-date", required=True)

    args = parser.parse_args()
    try:
        if args.command == "resolve-key":
            print(resolve_api_key(args.profile, args.config_path, args.working_directory))
        elif args.command == "account-id":
            print(extract_account_id(args.account_json))
        elif args.command == "validate-url":
            validate_url_is_allowed(args.url, args.allowed_hosts, base_url=args.base_url)
        elif args.command == "validate-date":
            validate_snapshot_date(args.snapshot_date)
        elif args.command == "build-payload":
            build_payload_file(
                Path(args.audit_json),
                Path(args.payload_json),
                Path(args.report_md),
                args.snapshot_date,
            )
    except Exception as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    return 0


def resolve_api_key(profile: str, config_path: str, working_directory: str) -> str:
    if tomllib is None:
        raise ValueError("Python TOML support is required: use Python 3.11+ or install tomli.")
    path = resolve_config_path(config_path, Path(working_directory))
    with path.open("rb") as f:
        config = tomllib.load(f)

    raw_profiles = config.get("profiles")
    if not isinstance(raw_profiles, dict):
        raise ValueError(f"{path} does not define [profiles].")

    profile_data = resolve_profile(raw_profiles, profile, [])
    raw_value = profile_data.get("api_key")
    if not raw_value:
        raise ValueError(
            f"profile '{profile}' in {path} does not define api_key."
        )
    value = interpolate_env(str(raw_value))
    if not value:
        raise ValueError(f"profile '{profile}' api_key resolved to an empty value.")
    if any(ord(char) < 32 or ord(char) == 127 for char in value):
        raise ValueError(f"profile '{profile}' api_key contains control characters.")
    return value


def resolve_config_path(config_path: str, working_directory: Path) -> Path:
    base = working_directory.expanduser().resolve()
    if config_path:
        return resolve_path(config_path, base)
    if os.environ.get("WORAI_CONFIG"):
        return resolve_path(os.environ["WORAI_CONFIG"], base)

    current = base
    for directory in [current, *current.parents]:
        candidate = directory / "worai.toml"
        if candidate.exists():
            return candidate

    for candidate in [
        Path("~/.config/worai/config.toml").expanduser(),
        Path("~/.worai.toml").expanduser(),
    ]:
        if candidate.exists():
            return candidate.resolve()
    return (base / "worai.toml").resolve()


def resolve_path(value: str, base: Path) -> Path:
    path = Path(value).expanduser()
    return path.resolve() if path.is_absolute() else (base / path).resolve()


def resolve_profile(
    profiles: dict[str, Any], profile: str, stack: list[str]
) -> dict[str, Any]:
    if profile in stack:
        raise ValueError(f"profile inheritance cycle detected: {' -> '.join(stack + [profile])}")
    node = profiles.get(profile)
    if not isinstance(node, dict):
        raise ValueError(f"profile '{profile}' was not found.")

    base = profiles.get("_base")
    merged: dict[str, Any] = dict(base) if isinstance(base, dict) and profile != "_base" else {}
    parent_name = node.get("inherit")
    if parent_name:
        merged.update(resolve_profile(profiles, str(parent_name), stack + [profile]))
    merged.update(node)
    return merged


def interpolate_env(value: str) -> str:
    def replace(match: re.Match[str]) -> str:
        name = match.group(1)
        if name not in os.environ:
            raise ValueError(f"environment variable {name} referenced by api_key is unset.")
        return os.environ[name]

    return ENV_PATTERN.sub(replace, value)


def extract_account_id(raw: str) -> str:
    data = json.loads(raw)
    for key in ("account_id", "accountId", "id"):
        value = data.get(key) if isinstance(data, dict) else None
        candidate = str(value).strip() if value is not None else ""
        if candidate:
            if not re.fullmatch(r"[0-9]+", candidate):
                raise ValueError("account id must be numeric.")
            return candidate
    raise ValueError("account id not found in /accounts/me response.")


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


def build_payload_file(
    audit_json: Path, payload_json: Path, report_md: Path, snapshot_date: str
) -> None:
    with audit_json.open("r", encoding="utf-8") as f:
        audit = json.load(f)
    if not isinstance(audit, dict):
        raise ValueError("audit JSON root must be an object.")

    calculated_at = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    payload: dict[str, Any] = {
        "snapshot_date": snapshot_date,
        "calculated_at": calculated_at,
        "snapshot_origin": "calculated",
    }

    payload.update(map_audit_metrics(audit))
    validate_payload(payload)

    payload_json.parent.mkdir(parents=True, exist_ok=True)
    report_md.parent.mkdir(parents=True, exist_ok=True)
    with payload_json.open("w", encoding="utf-8") as f:
        json.dump(payload, f, indent=2, sort_keys=True)
        f.write("\n")
    with report_md.open("w", encoding="utf-8") as f:
        f.write(render_report(payload))


def map_audit_metrics(audit: dict[str, Any]) -> dict[str, Any]:
    result: dict[str, Any] = {}

    direct_mapping = {
        "total_entities": "all_total_entities",
        "total_properties": "all_total_properties",
        "total_triples": "all_total_triples",
        "edges": "all_edges_count",
        "entity_types": "all_entity_types",
        "properties": "all_properties_by_predicate",
    }
    for source, target in direct_mapping.items():
        value = sanitize_metric(audit.get(source))
        if value is not None:
            result[target] = value

    count_sections = {
        "unique_urls": "all_unique_urls_count",
        "orphans": "all_orphans_count",
        "broken_links": "all_broken_links_count",
        "duplicates": "all_duplicates_count",
    }
    for section, target in count_sections.items():
        value = count_from_section(audit.get(section))
        if value is not None:
            result[target] = value

    isolated = audit.get("isolated_graphs")
    if isinstance(isolated, dict):
        value = sanitize_metric(isolated.get("component_count"))
        if value is not None:
            result["all_isolated_graphs_count"] = value

    ratio = audit.get("edge_node_ratio")
    if isinstance(ratio, dict):
        for source, target in {
            "ratio": "all_edge_node_ratio",
            "edges": "all_edge_node_ratio_edges",
            "nodes": "all_edge_node_ratio_nodes",
        }.items():
            value = sanitize_metric(ratio.get(source))
            if value is not None:
                result[target] = value

    rich = audit.get("rich_snippets")
    if isinstance(rich, dict):
        valid = sanitize_metric(rich.get("eligible_valid")) or {}
        invalid = sanitize_metric(rich.get("eligible_invalid")) or {}
        if isinstance(valid, dict):
            result["rich_snippets_valid_count"] = sum_numeric_values(valid)
        if isinstance(invalid, dict):
            result["rich_snippets_invalid_count"] = sum_numeric_values(invalid)
        by_type = rich_snippets_by_type(valid, invalid)
        if by_type:
            result["rich_snippets_by_type"] = by_type

    schema = audit.get("schema_compliance")
    if isinstance(schema, list):
        result["schema_compliance_urls_checked"] = len(schema)
        result["schema_compliance_errors"] = sum(
            non_negative_int(row.get("error_count"))
            for row in schema
            if isinstance(row, dict)
        )
        result["schema_compliance_warnings"] = sum(
            non_negative_int(row.get("warning_count"))
            for row in schema
            if isinstance(row, dict)
        )

    for key, value in audit.items():
        if key in FORBIDDEN_BODY_FIELDS or key in KNOWN_METADATA_FIELDS or key in direct_mapping:
            continue
        if key in count_sections or key in {"isolated_graphs", "edge_node_ratio", "rich_snippets", "schema_compliance"}:
            continue
        if key.startswith(("all_", "public_", "private_", "graph_health_")):
            sanitized = sanitize_metric(value)
            if sanitized is not None:
                result[key] = sanitized

    return result


def count_from_section(value: Any) -> int | float | None:
    if isinstance(value, dict):
        return sanitize_metric(value.get("count"))
    return sanitize_metric(value)


def rich_snippets_by_type(valid: Any, invalid: Any) -> dict[str, dict[str, int | float]]:
    types = set()
    if isinstance(valid, dict):
        types.update(valid)
    if isinstance(invalid, dict):
        types.update(invalid)
    return {
        type_name: {
            "valid": non_negative_number(valid.get(type_name) if isinstance(valid, dict) else 0),
            "invalid": non_negative_number(invalid.get(type_name) if isinstance(invalid, dict) else 0),
        }
        for type_name in sorted(types)
    }


def sanitize_metric(value: Any) -> Any:
    if isinstance(value, bool):
        return None
    if isinstance(value, int | float):
        if not math.isfinite(value) or value < 0:
            return None
        return value
    if isinstance(value, dict):
        sanitized: dict[str, Any] = {}
        for key, child in value.items():
            metric = sanitize_metric(child)
            if metric is not None:
                sanitized[str(key)] = metric
        return sanitized if sanitized else None
    return None


def sum_numeric_values(value: dict[str, Any]) -> int | float:
    total: int | float = 0
    for child in value.values():
        if isinstance(child, int | float) and not isinstance(child, bool) and child >= 0:
            total += child
    return total


def non_negative_int(value: Any) -> int:
    number = non_negative_number(value)
    return int(number)


def non_negative_number(value: Any) -> int | float:
    if isinstance(value, bool) or not isinstance(value, int | float) or value < 0:
        return 0
    return value


def validate_payload(payload: dict[str, Any]) -> None:
    def validate_object(values: dict[str, Any]) -> None:
        for key, value in values.items():
            if key in FORBIDDEN_BODY_FIELDS:
                raise ValueError(f"payload contains forbidden field {key}.")
            if key in KNOWN_METADATA_FIELDS:
                continue
            if isinstance(value, bool):
                raise ValueError(f"payload field {key} must not be boolean.")
            if isinstance(value, int | float):
                if not math.isfinite(value) or value < 0:
                    raise ValueError(f"payload field {key} must be finite and non-negative.")
            elif isinstance(value, dict):
                validate_object(value)
            else:
                raise ValueError(f"payload field {key} must be a number or object.")

    validate_object(payload)


def render_report(payload: dict[str, Any]) -> str:
    lines = [
        "## Graph KPI Report",
        "",
        f"- Snapshot date: `{payload['snapshot_date']}`",
        f"- Calculated at: `{payload['calculated_at']}`",
        f"- KPI fields: `{len(payload) - len(KNOWN_METADATA_FIELDS)}`",
    ]
    for key in (
        "all_total_entities",
        "all_total_properties",
        "all_total_triples",
        "all_edges_count",
        "graph_health_score",
    ):
        if key in payload:
            lines.append(f"- {key}: `{payload[key]}`")
    lines.append("")
    return "\n".join(lines)


if __name__ == "__main__":
    raise SystemExit(main())
