#!/usr/bin/env python3
"""Validate release-specific manual QA evidence for Impuls.

The canonical scenario inventory stays in the Behavioral QA Matrix. This check
requires each release evidence record to account explicitly for every scenario
whose final contract cannot be proven by automated CI alone.

Standard-library only by design.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
POLICY_PATH = ROOT / "Scripts/release-qa-policy.json"
VERSION_RE = re.compile(r"^(\d+)\.(\d+)\.(\d+)$")
SHA_RE = re.compile(r"^[0-9a-f]{40}$")
MATRIX_ROW_RE = re.compile(
    r"^\|\s*([A-Z]+-\d{2})\s*\|\s*([^|]+?)\s*\|\s*([^|]+?)\s*\|\s*([^|]+?)\s*\|\s*$"
)

ENV_START = "<!-- qa-environments:start -->"
ENV_END = "<!-- qa-environments:end -->"
RESULTS_START = "<!-- qa-results:start -->"
RESULTS_END = "<!-- qa-results:end -->"


@dataclass(frozen=True)
class Policy:
    enforce_from_version: tuple[int, int, int]
    matrix_path: Path
    evidence_directory: Path
    manual_modes: frozenset[str]
    result_values: frozenset[str]
    release_decisions: frozenset[str]
    environment_kinds: frozenset[str]


@dataclass(frozen=True)
class Scenario:
    identifier: str
    scenario: str
    mode: str


@dataclass(frozen=True)
class Environment:
    identifier: str
    kind: str
    hardware: str
    macos: str
    configuration: str
    tcc_state: str
    evidence_note: str


def parse_version(value: str) -> tuple[int, int, int]:
    match = VERSION_RE.fullmatch(value.strip())
    if match is None:
        raise ValueError(f"version must be x.y.z, got {value!r}")
    return tuple(int(part) for part in match.groups())


def current_app_version() -> str:
    for line in (ROOT / "Scripts/version").read_text(encoding="utf-8").splitlines():
        if line.startswith("VERSION="):
            value = line.partition("=")[2].strip()
            parse_version(value)
            return value
    raise ValueError("Scripts/version does not contain a valid VERSION=x.y.z")


def load_policy() -> Policy:
    raw = json.loads(POLICY_PATH.read_text(encoding="utf-8"))
    if raw.get("schema") != 1:
        raise ValueError("release QA policy schema must be 1")
    return Policy(
        enforce_from_version=parse_version(raw["enforce_from_version"]),
        matrix_path=ROOT / raw["matrix_path"],
        evidence_directory=ROOT / raw["evidence_directory"],
        manual_modes=frozenset(raw["manual_modes"]),
        result_values=frozenset(raw["result_values"]),
        release_decisions=frozenset(raw["release_decisions"]),
        environment_kinds=frozenset(raw["environment_kinds"]),
    )


def parse_frontmatter(text: str) -> dict[str, str]:
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        raise ValueError("YAML frontmatter is required")
    try:
        end = next(i for i in range(1, len(lines)) if lines[i].strip() == "---")
    except StopIteration as error:
        raise ValueError("YAML frontmatter is not closed") from error

    result: dict[str, str] = {}
    for line in lines[1:end]:
        if not line.strip() or line.lstrip().startswith("#") or ":" not in line:
            continue
        key, _, value = line.partition(":")
        result[key.strip()] = value.strip().strip("\"'")
    return result


def parse_matrix(text: str, manual_modes: frozenset[str]) -> dict[str, Scenario]:
    scenarios: dict[str, Scenario] = {}
    for line in text.splitlines():
        match = MATRIX_ROW_RE.fullmatch(line.strip())
        if match is None:
            continue
        identifier, scenario, mode, _expected = (part.strip() for part in match.groups())
        if mode not in manual_modes:
            continue
        if identifier in scenarios:
            raise ValueError(f"duplicate QA scenario ID in matrix: {identifier}")
        scenarios[identifier] = Scenario(identifier, scenario, mode)
    if not scenarios:
        raise ValueError("Behavioral QA Matrix contains no manual/mixed scenarios")
    return scenarios


def marked_block(text: str, start: str, end: str) -> str:
    if text.count(start) != 1 or text.count(end) != 1:
        raise ValueError(f"expected exactly one {start!r} and one {end!r}")
    before, _, remainder = text.partition(start)
    block, separator, _after = remainder.partition(end)
    if not separator or before.find(end) != -1:
        raise ValueError(f"invalid marker order for {start!r} / {end!r}")
    return block


def table_rows(block: str, expected_header: list[str]) -> list[list[str]]:
    rows: list[list[str]] = []
    header_seen = False
    for raw_line in block.splitlines():
        line = raw_line.strip()
        if not line.startswith("|") or not line.endswith("|"):
            continue
        cells = [cell.strip() for cell in line[1:-1].split("|")]
        if not header_seen:
            if cells != expected_header:
                raise ValueError(
                    f"table header must be {expected_header!r}, got {cells!r}"
                )
            header_seen = True
            continue
        if all(re.fullmatch(r":?-{3,}:?", cell) for cell in cells):
            continue
        if len(cells) != len(expected_header):
            raise ValueError(f"table row has {len(cells)} cells, expected {len(expected_header)}")
        rows.append(cells)
    if not header_seen:
        raise ValueError(f"table header not found: {expected_header!r}")
    return rows


def parse_environments(text: str, policy: Policy) -> tuple[dict[str, Environment], list[str]]:
    errors: list[str] = []
    try:
        rows = table_rows(
            marked_block(text, ENV_START, ENV_END),
            [
                "Environment",
                "Kind",
                "Hardware",
                "macOS",
                "Display / power / devices",
                "TCC state",
                "Evidence note",
            ],
        )
    except ValueError as error:
        return {}, [str(error)]

    environments: dict[str, Environment] = {}
    for cells in rows:
        environment = Environment(*cells)
        if not re.fullmatch(r"[A-Z0-9][A-Z0-9._-]{1,31}", environment.identifier):
            errors.append(f"invalid environment ID {environment.identifier!r}")
            continue
        if environment.identifier == "NONE":
            errors.append("NONE is reserved for scenarios that were not exercised")
            continue
        if environment.identifier in environments:
            errors.append(f"duplicate environment ID {environment.identifier}")
            continue
        if environment.kind not in policy.environment_kinds:
            errors.append(
                f"environment {environment.identifier}: unknown kind {environment.kind!r}"
            )
        for label, value in (
            ("hardware", environment.hardware),
            ("macOS", environment.macos),
            ("configuration", environment.configuration),
            ("TCC state", environment.tcc_state),
            ("evidence note", environment.evidence_note),
        ):
            if not value:
                errors.append(f"environment {environment.identifier}: {label} must not be blank")
        environments[environment.identifier] = environment
    return environments, errors


def section_has_content(text: str, heading: str) -> bool:
    pattern = re.compile(
        rf"(?ms)^##\s+{re.escape(heading)}\s*$\n(.*?)(?=^##\s+|\Z)"
    )
    match = pattern.search(text)
    if match is None:
        return False
    content = match.group(1).strip()
    return bool(content and content.lower() not in {"none", "- none", "нет", "- нет"})


def validate_document(
    version: str,
    text: str,
    scenarios: dict[str, Scenario],
    policy: Policy,
) -> list[str]:
    errors: list[str] = []
    parsed_version = parse_version(version)

    try:
        metadata = parse_frontmatter(text)
    except ValueError as error:
        return [str(error)]

    required_metadata = {
        "title",
        "type",
        "status",
        "documentation_version",
        "app_version",
        "last_reviewed",
        "tags",
        "evidence_schema",
        "release_commit",
        "release_decision",
    }
    missing = required_metadata - metadata.keys()
    if missing:
        errors.append(f"missing frontmatter keys: {', '.join(sorted(missing))}")
    if metadata.get("type") != "qa-evidence":
        errors.append("frontmatter type must be qa-evidence")
    if metadata.get("app_version") != version:
        errors.append(
            f"frontmatter app_version {metadata.get('app_version')!r} does not match file version {version}"
        )
    if metadata.get("evidence_schema") != "1":
        errors.append("frontmatter evidence_schema must be 1")
    commit = metadata.get("release_commit", "")
    if not SHA_RE.fullmatch(commit):
        errors.append("frontmatter release_commit must be a 40-character lowercase commit SHA")
    decision = metadata.get("release_decision", "")
    if decision not in policy.release_decisions:
        errors.append(f"unknown release_decision {decision!r}")
    if parsed_version >= policy.enforce_from_version and decision == "retrospective":
        errors.append(
            f"retrospective decision is forbidden from {'.'.join(map(str, policy.enforce_from_version))} onward"
        )

    environments, environment_errors = parse_environments(text, policy)
    errors.extend(environment_errors)

    try:
        result_rows = table_rows(
            marked_block(text, RESULTS_START, RESULTS_END),
            ["ID", "Result", "Environment", "Evidence", "Notes"],
        )
    except ValueError as error:
        return errors + [str(error)]

    results: dict[str, tuple[str, str, str, str]] = {}
    for identifier, result, environment_id, evidence, notes in result_rows:
        if identifier in results:
            errors.append(f"duplicate QA result row {identifier}")
            continue
        scenario = scenarios.get(identifier)
        if scenario is None:
            errors.append(f"result row {identifier} is not a manual/mixed matrix scenario")
            continue
        if result not in policy.result_values:
            errors.append(f"{identifier}: unknown result {result!r}")
        if not evidence:
            errors.append(f"{identifier}: Evidence must not be blank")
        if result in {"fail", "blocked", "not-run", "not-applicable", "not-recorded"} and not notes:
            errors.append(f"{identifier}: {result} requires explanatory Notes")
        if result == "not-recorded" and parsed_version >= policy.enforce_from_version:
            errors.append(f"{identifier}: not-recorded is forbidden for enforced releases")

        if environment_id == "NONE":
            if result in {"pass", "fail", "blocked"}:
                errors.append(f"{identifier}: {result} requires a concrete test environment")
        elif environment_id not in environments:
            errors.append(f"{identifier}: unknown environment {environment_id!r}")
        else:
            kind = environments[environment_id].kind
            if result in {"pass", "fail", "blocked"}:
                if scenario.mode in {"manual-macos", "manual-hardware", "mixed"} and kind not in {
                    "real-mac",
                    "real-mac-hardware",
                }:
                    errors.append(
                        f"{identifier}: {scenario.mode} result {result} must use a real-mac environment"
                    )
                if scenario.mode == "manual-hardware" and kind != "real-mac-hardware":
                    errors.append(
                        f"{identifier}: manual-hardware result {result} must use real-mac-hardware"
                    )
                if scenario.mode == "manual-service" and kind not in {
                    "real-mac",
                    "real-mac-hardware",
                    "service",
                }:
                    errors.append(
                        f"{identifier}: manual-service result {result} requires real/service evidence"
                    )
        results[identifier] = (result, environment_id, evidence, notes)

    missing_ids = sorted(set(scenarios) - set(results))
    extra_ids = sorted(set(results) - set(scenarios))
    if missing_ids:
        errors.append("missing manual/mixed QA rows: " + ", ".join(missing_ids))
    if extra_ids:
        errors.append("unexpected QA rows: " + ", ".join(extra_ids))

    result_values = {value[0] for value in results.values()}
    gaps = {"fail", "blocked", "not-run", "not-recorded"} & result_values
    if decision == "certified":
        bad = sorted(
            identifier
            for identifier, (result, _env, _evidence, _notes) in results.items()
            if result not in {"pass", "not-applicable"}
        )
        if bad:
            errors.append(
                "certified release contains unresolved manual QA rows: " + ", ".join(bad)
            )
        if not any(env.kind in {"real-mac", "real-mac-hardware"} for env in environments.values()):
            errors.append("certified release requires at least one real Mac environment")
    elif decision == "ship-with-known-gaps":
        if not gaps:
            errors.append("ship-with-known-gaps requires at least one explicit unresolved result")
        if not section_has_content(text, "Known gaps"):
            errors.append("ship-with-known-gaps requires a non-empty ## Known gaps section")
    elif decision == "blocked":
        if not ({"fail", "blocked"} & result_values):
            errors.append("blocked release decision requires at least one fail/blocked QA row")

    return errors


def evidence_files(policy: Policy) -> list[Path]:
    if not policy.evidence_directory.is_dir():
        return []
    return sorted(
        path
        for path in policy.evidence_directory.glob("*.md")
        if path.name not in {"README.md", "TEMPLATE.md"}
    )


def validate_repository(policy: Policy, requested_version: str | None = None) -> list[str]:
    errors: list[str] = []
    try:
        scenarios = parse_matrix(
            policy.matrix_path.read_text(encoding="utf-8"), policy.manual_modes
        )
    except (OSError, ValueError) as error:
        return [f"matrix: {error}"]

    files = evidence_files(policy)
    if not files:
        return ["no release QA evidence files found"]

    for path in files:
        version = path.stem
        try:
            parse_version(version)
        except ValueError as error:
            errors.append(f"{path.relative_to(ROOT)}: {error}")
            continue
        document_errors = validate_document(
            version, path.read_text(encoding="utf-8"), scenarios, policy
        )
        errors.extend(f"{path.relative_to(ROOT)}: {error}" for error in document_errors)

    version = requested_version or current_app_version()
    expected = policy.evidence_directory / f"{version}.md"
    if not expected.is_file():
        errors.append(
            f"current/release version {version} requires {expected.relative_to(ROOT)}"
        )
    return errors


def release_gate_errors(policy: Policy, version: str) -> list[str]:
    errors = validate_repository(policy, version)
    path = policy.evidence_directory / f"{version}.md"
    if errors or not path.is_file():
        return errors
    metadata = parse_frontmatter(path.read_text(encoding="utf-8"))
    decision = metadata.get("release_decision")
    parsed = parse_version(version)
    if decision == "blocked":
        errors.append(f"release {version} is explicitly blocked by QA evidence")
    if parsed >= policy.enforce_from_version and decision not in {
        "certified",
        "ship-with-known-gaps",
    }:
        errors.append(
            f"release {version} must be certified or ship-with-known-gaps before release"
        )
    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", help="version that must have an evidence record")
    parser.add_argument(
        "--release-gate",
        action="store_true",
        help="also enforce that the selected release decision permits shipping",
    )
    parser.add_argument(
        "--all",
        action="store_true",
        help="accepted for readability; repository validation always checks all evidence records",
    )
    args = parser.parse_args()

    try:
        policy = load_policy()
        version = args.version or current_app_version()
        parse_version(version)
        errors = (
            release_gate_errors(policy, version)
            if args.release_gate
            else validate_repository(policy, version)
        )
    except (OSError, KeyError, ValueError, json.JSONDecodeError) as error:
        print(f"Release QA evidence validation failed: {error}", file=sys.stderr)
        return 1

    if errors:
        print("Release QA evidence validation failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1

    print(
        f"Release QA evidence OK: current/release version {version}; "
        f"manual evidence enforcement starts at {'.'.join(map(str, policy.enforce_from_version))}."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
