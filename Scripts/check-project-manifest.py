#!/usr/bin/env python3
"""Validate the routing-only PROJECT-MANIFEST.json against the repository."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MANIFEST_PATH = ROOT / "PROJECT-MANIFEST.json"
EXPECTED_NETWORK_OWNERS = {
    "Sources/Impuls/Services/UpdateService.swift",
    "Sources/Impuls/Services/WebMusicPlayer.swift",
    "Sources/Impuls/Services/VersionTelemetryService.swift",
}
IPV4_RE = re.compile(r"(?<![\d.])(?:\d{1,3}\.){3}\d{1,3}(?![\d.])")
FEATURE_RE = re.compile(r"\bfeature\(\.(\w+)\s*,")


def load_manifest() -> dict:
    return json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))


def repo_path(value: str, label: str, errors: list[str]) -> None:
    if not (ROOT / value).exists():
        errors.append(f"{label}: repository path does not exist: {value}")


def feature_catalog_ids(path: str) -> list[str]:
    return FEATURE_RE.findall((ROOT / path).read_text(encoding="utf-8"))


def validate_module_ids(data: dict, errors: list[str]) -> None:
    modules = data.get("modules")
    if not isinstance(modules, list) or not modules:
        errors.append("modules must be a non-empty list")
        return
    ids = [entry.get("id") for entry in modules if isinstance(entry, dict)]
    if len(ids) != len(modules) or any(not isinstance(item, str) or not item for item in ids):
        errors.append("every module must have a non-empty string id")
        return
    if len(ids) != len(set(ids)):
        errors.append("module ids must be unique")
    catalog_path = data.get("product", {}).get("feature_catalog")
    if not isinstance(catalog_path, str):
        errors.append("product.feature_catalog must be a path")
        return
    try:
        shipped = feature_catalog_ids(catalog_path)
    except OSError as error:
        errors.append(f"cannot read feature catalog: {error}")
        return
    if len(shipped) != len(set(shipped)):
        errors.append("AppFeatureCatalog contains duplicate shipped module ids")
    if set(ids) != set(shipped):
        errors.append(
            "module ids drifted from AppFeatureCatalog: "
            f"manifest={sorted(ids)}, catalog={sorted(shipped)}"
        )


def iter_repository_paths(data: dict):
    product = data.get("product", {})
    for key in ("version_source", "package_manifest", "feature_catalog"):
        if isinstance(product.get(key), str):
            yield f"product.{key}", product[key]
    for key, value in data.get("knowledge_entrypoints", {}).items():
        if isinstance(value, str):
            yield f"knowledge_entrypoints.{key}", value
    for index, module in enumerate(data.get("modules", [])):
        if not isinstance(module, dict):
            continue
        if isinstance(module.get("canonical_doc"), str):
            yield f"modules[{index}].canonical_doc", module["canonical_doc"]
        for path in module.get("core_sources", []):
            if isinstance(path, str):
                yield f"modules[{index}].core_sources", path
    for section in ("presentation_surfaces", "permission_domains"):
        for index, entry in enumerate(data.get(section, [])):
            if not isinstance(entry, dict):
                continue
            for key in ("canonical_docs", "core_sources"):
                for path in entry.get(key, []):
                    if isinstance(path, str):
                        yield f"{section}[{index}].{key}", path
    for index, owner in enumerate(data.get("network_owners", [])):
        if not isinstance(owner, dict):
            continue
        for key in ("source", "canonical_doc"):
            if isinstance(owner.get(key), str):
                yield f"network_owners[{index}].{key}", owner[key]
    for section in ("persistence", "performance"):
        entry = data.get(section, {})
        if isinstance(entry, dict):
            for key in ("canonical_docs", "core_sources"):
                for path in entry.get(key, []):
                    if isinstance(path, str):
                        yield f"{section}.{key}", path
    security = data.get("security", {})
    for path in security.get("canonical_docs", []):
        if isinstance(path, str):
            yield "security.canonical_docs", path
    if isinstance(security.get("public_privacy_document"), str):
        yield "security.public_privacy_document", security["public_privacy_document"]
    dependencies = data.get("dependencies", {})
    for key in ("canonical_doc", "policy", "lockfile", "package_manifest"):
        if isinstance(dependencies.get(key), str):
            yield f"dependencies.{key}", dependencies[key]
    release = data.get("release", {})
    for key in ("canonical_docs", "workflows"):
        for path in release.get(key, []):
            if isinstance(path, str):
                yield f"release.{key}", path
    web = data.get("web_and_collector", {})
    for key in ("website_doc", "website_root", "collector_doc", "collector_root"):
        if isinstance(web.get(key), str):
            yield f"web_and_collector.{key}", web[key]
    for path in data.get("validation", {}).get("repository_paths", []):
        if isinstance(path, str):
            yield "validation.repository_paths", path


def validate_data(data: dict) -> list[str]:
    errors: list[str] = []
    required = {
        "schema_version", "manifest_role", "source_of_truth_rule", "product",
        "knowledge_entrypoints", "modules", "presentation_surfaces",
        "network_owners", "permission_domains", "persistence", "performance",
        "security", "dependencies", "release", "web_and_collector",
        "operations_boundary", "validation"
    }
    missing = required - data.keys()
    if missing:
        errors.append("missing top-level sections: " + ", ".join(sorted(missing)))
    if data.get("schema_version") != 1:
        errors.append("schema_version must be 1")
    if data.get("manifest_role") != "routing-only":
        errors.append("manifest_role must remain routing-only")

    validate_module_ids(data, errors)
    owners = data.get("network_owners")
    if not isinstance(owners, list):
        errors.append("network_owners must be a list")
    else:
        sources = {
            owner.get("source") for owner in owners
            if isinstance(owner, dict) and isinstance(owner.get("source"), str)
        }
        if len(owners) != 3 or sources != EXPECTED_NETWORK_OWNERS:
            errors.append(
                "network owner set must remain the explicit three-owner contract; "
                "a fourth owner requires architecture/security review"
            )

    operations = data.get("operations_boundary", {})
    if operations.get("public_software_repo") != "TumanovNV/impuls":
        errors.append("operations_boundary.public_software_repo is invalid")
    if operations.get("private_operations_repo") != "TumanovNV/office-it-docs":
        errors.append("operations_boundary.private_operations_repo is invalid")
    if operations.get("private_entrypoint") != "Проекты/Impuls.md":
        errors.append("operations_boundary.private_entrypoint is invalid")

    for label, path in iter_repository_paths(data):
        repo_path(path, label, errors)

    version_source = data.get("product", {}).get("version_source")
    if isinstance(version_source, str) and (ROOT / version_source).is_file():
        if not re.search(
            r"(?m)^VERSION=\d+\.\d+\.\d+\s*$",
            (ROOT / version_source).read_text(encoding="utf-8"),
        ):
            errors.append("product.version_source does not contain VERSION=x.y.z")

    serialized = json.dumps(data, ensure_ascii=False)
    for candidate in IPV4_RE.findall(serialized):
        octets = [int(part) for part in candidate.split(".")]
        if all(0 <= part <= 255 for part in octets):
            errors.append(f"public PROJECT-MANIFEST.json must not contain raw IPv4 address: {candidate}")
    return errors


def main() -> int:
    try:
        data = load_manifest()
        errors = validate_data(data)
    except (OSError, json.JSONDecodeError) as error:
        print(f"PROJECT-MANIFEST validation error: {error}", file=sys.stderr)
        return 2
    if errors:
        print("PROJECT-MANIFEST validation failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1
    print(
        f"PROJECT-MANIFEST OK: {len(data['modules'])} shipped modules, "
        f"{len(data['network_owners'])} network owners, routing paths valid."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
