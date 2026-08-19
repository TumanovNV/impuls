#!/usr/bin/env python3
"""Validate Impuls third-party Swift package supply-chain policy.

The check intentionally requires every resolved pin, including future
transitive pins, to be explicitly approved. Direct packages must also appear
as exact-version requirements in Package.swift. This turns an added package or
retargeted revision into an explicit security/documentation change.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
POLICY_PATH = ROOT / "Scripts" / "dependency-policy.json"
RESOLVED_PATH = ROOT / "Package.resolved"
PACKAGE_PATH = ROOT / "Package.swift"
DIRECT_RE = re.compile(
    r'\.package\(\s*url:\s*"([^"]+)"\s*,\s*exact:\s*"([^"]+)"\s*\)',
    re.DOTALL,
)


def load_policy() -> dict:
    return json.loads(POLICY_PATH.read_text(encoding="utf-8"))


def load_resolved() -> dict:
    return json.loads(RESOLVED_PATH.read_text(encoding="utf-8"))


def direct_dependencies() -> dict[str, str]:
    text = PACKAGE_PATH.read_text(encoding="utf-8")
    return {location: version for location, version in DIRECT_RE.findall(text)}


def normalized_pins(resolved: dict, errors: list[str]) -> dict[str, dict]:
    if resolved.get("version") != 2:
        errors.append("Package.resolved format version must remain 2 or the checker must be reviewed")
    pins = resolved.get("pins")
    if not isinstance(pins, list):
        errors.append("Package.resolved pins must be a list")
        return {}

    result: dict[str, dict] = {}
    for pin in pins:
        if not isinstance(pin, dict):
            errors.append("Package.resolved contains a non-object pin")
            continue
        identity = pin.get("identity")
        state = pin.get("state")
        if not isinstance(identity, str) or not identity:
            errors.append("resolved pin has no identity")
            continue
        if identity in result:
            errors.append(f"duplicate resolved pin identity: {identity}")
            continue
        if pin.get("kind") != "remoteSourceControl":
            errors.append(f"resolved pin {identity} is not remoteSourceControl")
        if not isinstance(state, dict):
            errors.append(f"resolved pin {identity} has no state")
            continue
        result[identity] = {
            "location": pin.get("location"),
            "version": state.get("version"),
            "revision": state.get("revision"),
        }
    return result


def validate_data(policy: dict, resolved: dict, direct: dict[str, str]) -> list[str]:
    errors: list[str] = []
    if policy.get("schema_version") != 1:
        errors.append("dependency policy schema_version must be 1")
    if policy.get("package_manager") != "swiftpm":
        errors.append("dependency policy package_manager must be swiftpm")

    dependencies = policy.get("dependencies")
    if not isinstance(dependencies, list):
        errors.append("dependency policy dependencies must be a list")
        return errors

    approved: dict[str, dict] = {}
    for dependency in dependencies:
        if not isinstance(dependency, dict):
            errors.append("dependency policy contains a non-object entry")
            continue
        required = {
            "identity", "location", "version", "revision", "direct",
            "requirement", "purpose", "canonical_doc"
        }
        missing = required - dependency.keys()
        if missing:
            errors.append(
                f"dependency {dependency.get('identity', '<unknown>')} missing: "
                + ", ".join(sorted(missing))
            )
            continue
        identity = dependency["identity"]
        if not isinstance(identity, str) or not identity:
            errors.append("dependency identity must be a non-empty string")
            continue
        if identity in approved:
            errors.append(f"duplicate approved dependency identity: {identity}")
            continue
        if dependency["requirement"] != "exact":
            errors.append(f"direct dependency policy must use exact requirement: {identity}")
        if not re.fullmatch(r"[0-9a-f]{40}", str(dependency["revision"])):
            errors.append(f"dependency revision must be a full 40-character Git SHA: {identity}")
        doc = ROOT / str(dependency["canonical_doc"])
        if not doc.is_file():
            errors.append(f"dependency {identity} canonical doc is missing: {dependency['canonical_doc']}")
        approved[identity] = dependency

    pins = normalized_pins(resolved, errors)
    if set(approved) != set(pins):
        errors.append(
            "resolved dependency set differs from explicit allowlist: "
            f"approved={sorted(approved)}, resolved={sorted(pins)}"
        )

    for identity in sorted(set(approved) & set(pins)):
        expected = approved[identity]
        actual = pins[identity]
        for field in ("location", "version", "revision"):
            if expected[field] != actual[field]:
                errors.append(
                    f"dependency {identity} {field} mismatch: "
                    f"policy={expected[field]!r}, resolved={actual[field]!r}"
                )
        if expected["direct"]:
            if direct.get(expected["location"]) != expected["version"]:
                errors.append(
                    f"direct dependency {identity} must appear in Package.swift "
                    f"with exact version {expected['version']}"
                )

    approved_direct_locations = {
        dependency["location"]
        for dependency in approved.values()
        if dependency.get("direct") is True
    }
    if set(direct) != approved_direct_locations:
        errors.append(
            "Package.swift direct package set differs from approved direct dependencies: "
            f"policy={sorted(approved_direct_locations)}, package={sorted(direct)}"
        )

    return errors


def main() -> int:
    try:
        policy = load_policy()
        resolved = load_resolved()
        direct = direct_dependencies()
        errors = validate_data(policy, resolved, direct)
    except (OSError, json.JSONDecodeError) as error:
        print(f"Dependency policy validation error: {error}", file=sys.stderr)
        return 2

    if errors:
        print("Dependency supply-chain validation failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1

    print(
        f"Dependency policy OK: {len(policy['dependencies'])} explicitly approved "
        "Swift package pin(s), exact versions and revisions match."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
