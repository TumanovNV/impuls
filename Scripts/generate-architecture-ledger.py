#!/usr/bin/env python3
"""Generate and validate the release-to-architecture ledger."""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
INPUT = ROOT / "Scripts" / "architecture-milestones.json"
OUTPUT = ROOT / "knowledge-base" / "11-history" / "release-architecture-ledger.md"
DOC_VERSION = "1.3"
SEMVER_RE = re.compile(r"^\d+\.\d+\.\d+$")


def app_version() -> str:
    for line in (ROOT / "Scripts" / "version").read_text(encoding="utf-8").splitlines():
        if line.startswith("VERSION="):
            return line.partition("=")[2].strip()
    raise ValueError("Scripts/version has no VERSION=")


def version_tuple(value: str) -> tuple[int, int, int]:
    if not SEMVER_RE.fullmatch(value):
        raise ValueError(f"invalid semantic version: {value}")
    return tuple(int(part) for part in value.split("."))


def load_data() -> dict:
    return json.loads(INPUT.read_text(encoding="utf-8"))


def validate_data(data: dict) -> list[str]:
    errors: list[str] = []
    if data.get("schema_version") != 1:
        errors.append("architecture milestones schema_version must be 1")
    entries = data.get("entries")
    if not isinstance(entries, list) or not entries:
        errors.append("architecture milestone entries must be a non-empty list")
        return errors

    seen_ids: set[str] = set()
    ordered_versions: list[tuple[int, int, int]] = []
    current = version_tuple(app_version())

    for index, entry in enumerate(entries):
        if not isinstance(entry, dict):
            errors.append(f"entry {index} is not an object")
            continue
        required = {"version", "id", "category", "summary", "release_note", "canonical_docs", "adrs"}
        missing = required - entry.keys()
        if missing:
            errors.append(f"entry {index} missing: {', '.join(sorted(missing))}")
            continue
        try:
            version = version_tuple(entry["version"])
        except (TypeError, ValueError) as error:
            errors.append(f"entry {index}: {error}")
            continue
        ordered_versions.append(version)
        if version > current:
            errors.append(f"milestone {entry['version']} is newer than current app {app_version()}")

        milestone_id = entry["id"]
        if not isinstance(milestone_id, str) or not milestone_id:
            errors.append(f"entry {index} has invalid id")
        elif milestone_id in seen_ids:
            errors.append(f"duplicate milestone id: {milestone_id}")
        else:
            seen_ids.add(milestone_id)

        if not isinstance(entry["summary"], str) or not entry["summary"].strip():
            errors.append(f"milestone {milestone_id} has empty summary")
        if not isinstance(entry["category"], str) or not entry["category"].strip():
            errors.append(f"milestone {milestone_id} has empty category")

        expected_release = f"docs/releases/{entry['version']}.md"
        if entry["release_note"] != expected_release:
            errors.append(
                f"milestone {milestone_id} release_note must be {expected_release}"
            )
        release_path = ROOT / entry["release_note"]
        if not release_path.is_file():
            errors.append(f"milestone {milestone_id} release note is missing")
        else:
            first = release_path.read_text(encoding="utf-8").splitlines()[0].strip()
            if first != f"# Impuls {entry['version']}":
                errors.append(
                    f"milestone {milestone_id} release note title does not match version"
                )

        for field in ("canonical_docs", "adrs"):
            values = entry[field]
            if not isinstance(values, list):
                errors.append(f"milestone {milestone_id} {field} must be a list")
                continue
            for value in values:
                if not isinstance(value, str) or not (ROOT / value).is_file():
                    errors.append(f"milestone {milestone_id} references missing {field} path: {value}")

    if ordered_versions != sorted(ordered_versions):
        errors.append("architecture milestones must be sorted by release version")
    return errors


def relative_link(path: str) -> str:
    return os.path.relpath(ROOT / path, OUTPUT.parent).replace(os.sep, "/")


def links(paths: list[str]) -> str:
    if not paths:
        return "—"
    return "<br>".join(
        f"[{Path(path).name}]({relative_link(path)})" for path in paths
    )


def render(data: dict) -> str:
    version = app_version()
    lines = [
        "---",
        "title: Release Architecture Ledger",
        "type: generated-history",
        "status: active",
        f"documentation_version: {DOC_VERSION}",
        f"app_version: {version}",
        "last_reviewed: 2026-08-19",
        "tags: [impuls, history, releases, architecture, generated]",
        "---",
        "",
        "# Release Architecture Ledger",
        "",
        "> Generated from `Scripts/architecture-milestones.json`. Do not hand-edit this file.",
        "",
        "This is not a user-facing changelog. It records verified release points where a long-lived architecture, privacy, security, performance or ownership contract changed.",
        "",
        "| Release | Category | Architecture impact | Canonical docs | ADR | Release evidence |",
        "| --- | --- | --- | --- | --- | --- |",
    ]
    for entry in data["entries"]:
        release_link = relative_link(entry["release_note"])
        summary = entry["summary"].replace("|", "\\|")
        lines.append(
            f"| {entry['version']} | `{entry['category']}` | {summary} | "
            f"{links(entry['canonical_docs'])} | {links(entry['adrs'])} | "
            f"[release note]({release_link}) |"
        )
    lines.extend(
        [
            "",
            "## Maintenance contract",
            "",
            "Add a milestone only for a durable contract change, not every feature or bug fix. The release note is evidence that the change shipped; canonical docs describe the current contract; ADRs explain durable decisions when one exists.",
            "",
            "When a release introduces a new long-lived architecture boundary, update `Scripts/architecture-milestones.json`, run `python3 Scripts/generate-architecture-ledger.py`, and include the generated file in the same change.",
            "",
        ]
    )
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    try:
        data = load_data()
        errors = validate_data(data)
        if errors:
            print("Architecture milestone validation failed:", file=sys.stderr)
            for error in errors:
                print(f"- {error}", file=sys.stderr)
            return 1
        rendered = render(data)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"Architecture ledger error: {error}", file=sys.stderr)
        return 2

    if args.check:
        if not OUTPUT.is_file() or OUTPUT.read_text(encoding="utf-8") != rendered:
            print(
                "Generated architecture ledger is stale. Run: "
                "python3 Scripts/generate-architecture-ledger.py",
                file=sys.stderr,
            )
            return 1
        print(f"Architecture ledger OK: {len(data['entries'])} verified milestones.")
        return 0

    OUTPUT.write_text(rendered, encoding="utf-8")
    print(f"Wrote {OUTPUT.relative_to(ROOT)} with {len(data['entries'])} milestones.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
