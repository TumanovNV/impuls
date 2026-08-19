#!/usr/bin/env python3
"""Map a Git diff to Behavioral QA scenario IDs.

The mapping is intentionally curated and machine-readable. The checker does not
pretend to understand Swift semantics; it answers the safer question: which QA
contracts must a human/agent review when known behavioral ownership areas
change, and did a new behavioral source escape the map entirely?

Standard-library only by design.
"""

from __future__ import annotations

import argparse
import fnmatch
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RULES_PATH = ROOT / "Scripts/qa-impact-rules.json"
VERSION_RE = re.compile(r"^(\d+)\.(\d+)\.(\d+)$")
MATRIX_ROW_RE = re.compile(
    r"^\|\s*([A-Z]+-\d{2})\s*\|\s*([^|]+?)\s*\|\s*([^|]+?)\s*\|\s*([^|]+?)\s*\|\s*$"
)
EVIDENCE_ROW_RE = re.compile(r"^\|\s*([A-Z]+-\d{2})\s*\|\s*([a-z-]+)\s*\|")
RESULTS_START = "<!-- qa-results:start -->"
RESULTS_END = "<!-- qa-results:end -->"


@dataclass(frozen=True)
class Scenario:
    identifier: str
    scenario: str
    mode: str


@dataclass(frozen=True)
class Rule:
    identifier: str
    description: str
    source_globs: tuple[str, ...]
    test_globs: tuple[str, ...]
    qa_ids: tuple[str, ...]


@dataclass(frozen=True)
class Exemption:
    source_globs: tuple[str, ...]
    reason: str


@dataclass(frozen=True)
class Config:
    matrix_path: Path
    release_evidence_directory: Path
    tracked_source_globs: tuple[str, ...]
    exemptions: tuple[Exemption, ...]
    rules: tuple[Rule, ...]


@dataclass
class Impact:
    source_files: set[str]
    test_files: set[str]
    rules: set[str]


def git(*args: str) -> str:
    result = subprocess.run(
        ["git", *args],
        cwd=ROOT,
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or f"git {' '.join(args)} failed")
    return result.stdout


def matches(path: str, globs: tuple[str, ...] | list[str]) -> bool:
    return any(fnmatch.fnmatch(path, pattern) for pattern in globs)


def has_magic(pattern: str) -> bool:
    return any(token in pattern for token in ("*", "?", "["))


def parse_matrix(text: str) -> dict[str, Scenario]:
    scenarios: dict[str, Scenario] = {}
    for line in text.splitlines():
        match = MATRIX_ROW_RE.fullmatch(line.strip())
        if match is None:
            continue
        identifier, scenario, mode, _expected = (part.strip() for part in match.groups())
        if identifier in scenarios:
            raise ValueError(f"duplicate Behavioral QA ID: {identifier}")
        scenarios[identifier] = Scenario(identifier, scenario, mode)
    if not scenarios:
        raise ValueError("Behavioral QA Matrix contains no scenarios")
    return scenarios


def parse_version_text(text: str) -> str:
    for line in text.splitlines():
        if line.startswith("VERSION="):
            value = line.partition("=")[2].strip()
            if VERSION_RE.fullmatch(value) is None:
                raise ValueError(f"invalid VERSION value: {value!r}")
            return value
    raise ValueError("version file does not contain VERSION=x.y.z")


def current_version() -> str:
    return parse_version_text((ROOT / "Scripts/version").read_text(encoding="utf-8"))


def version_at(ref: str) -> str:
    return parse_version_text(git("show", f"{ref}:Scripts/version"))


def _require_string_list(raw: object, label: str, *, allow_empty: bool = False) -> tuple[str, ...]:
    if not isinstance(raw, list) or (not raw and not allow_empty):
        raise ValueError(f"{label} must be {'a ' if allow_empty else 'a non-empty '}list")
    if any(not isinstance(value, str) or not value.strip() for value in raw):
        raise ValueError(f"{label} must contain only non-empty strings")
    return tuple(value.strip() for value in raw)


def load_config() -> tuple[Config, dict[str, Scenario]]:
    raw = json.loads(RULES_PATH.read_text(encoding="utf-8"))
    if raw.get("schema_version") != 1:
        raise ValueError("qa impact rules schema_version must be 1")

    matrix_path = ROOT / raw.get("matrix_path", "")
    evidence_directory = ROOT / raw.get("release_evidence_directory", "")
    if not matrix_path.is_file():
        raise ValueError(f"matrix_path does not exist: {matrix_path.relative_to(ROOT)}")
    if not evidence_directory.is_dir():
        raise ValueError(
            f"release_evidence_directory does not exist: {evidence_directory.relative_to(ROOT)}"
        )
    scenarios = parse_matrix(matrix_path.read_text(encoding="utf-8"))

    tracked = _require_string_list(raw.get("tracked_source_globs"), "tracked_source_globs")

    exemptions: list[Exemption] = []
    for index, item in enumerate(raw.get("exemptions", [])):
        if not isinstance(item, dict):
            raise ValueError(f"exemptions[{index}] must be an object")
        globs = _require_string_list(item.get("source_globs"), f"exemptions[{index}].source_globs")
        reason = item.get("reason")
        if not isinstance(reason, str) or len(reason.strip()) < 20:
            raise ValueError(f"exemptions[{index}].reason must be a meaningful explanation")
        exemptions.append(Exemption(globs, reason.strip()))

    rule_items = raw.get("rules")
    if not isinstance(rule_items, list) or not rule_items:
        raise ValueError("rules must be a non-empty list")

    rules: list[Rule] = []
    seen_rule_ids: set[str] = set()
    covered_ids: set[str] = set()
    automated_with_tests: set[str] = set()

    for index, item in enumerate(rule_items):
        if not isinstance(item, dict):
            raise ValueError(f"rules[{index}] must be an object")
        identifier = item.get("id")
        description = item.get("description")
        if not isinstance(identifier, str) or not identifier.strip():
            raise ValueError(f"rules[{index}].id must be a non-empty string")
        identifier = identifier.strip()
        if identifier in seen_rule_ids:
            raise ValueError(f"duplicate QA impact rule id: {identifier}")
        seen_rule_ids.add(identifier)
        if not isinstance(description, str) or len(description.strip()) < 12:
            raise ValueError(f"rule {identifier}: description is too short")

        source_globs = _require_string_list(item.get("source_globs"), f"rule {identifier}.source_globs")
        test_globs = _require_string_list(
            item.get("test_globs", []), f"rule {identifier}.test_globs", allow_empty=True
        )
        qa_ids = _require_string_list(item.get("qa_ids"), f"rule {identifier}.qa_ids")

        unknown = sorted(set(qa_ids) - set(scenarios))
        if unknown:
            raise ValueError(f"rule {identifier} references unknown QA IDs: {', '.join(unknown)}")

        for pattern in (*source_globs, *test_globs):
            if not has_magic(pattern) and not (ROOT / pattern).is_file():
                raise ValueError(f"rule {identifier} points to missing file: {pattern}")

        covered_ids.update(qa_ids)
        if test_globs:
            automated_with_tests.update(
                qa_id for qa_id in qa_ids if scenarios[qa_id].mode == "automated"
            )
        rules.append(
            Rule(identifier, description.strip(), source_globs, test_globs, qa_ids)
        )

    uncovered = sorted(set(scenarios) - covered_ids)
    if uncovered:
        raise ValueError(
            "Behavioral QA scenarios without source/test traceability: " + ", ".join(uncovered)
        )

    automated = {identifier for identifier, scenario in scenarios.items() if scenario.mode == "automated"}
    automated_without_tests = sorted(automated - automated_with_tests)
    if automated_without_tests:
        raise ValueError(
            "automated QA IDs without a mapped test route: " + ", ".join(automated_without_tests)
        )

    return (
        Config(matrix_path, evidence_directory, tracked, tuple(exemptions), tuple(rules)),
        scenarios,
    )


def changed_files(base: str) -> set[str]:
    return {
        line.strip()
        for line in git("diff", "--name-only", f"{base}...HEAD").splitlines()
        if line.strip()
    }


def exemption_for(path: str, config: Config) -> Exemption | None:
    for exemption in config.exemptions:
        if matches(path, exemption.source_globs):
            return exemption
    return None


def evaluate_files(
    files: set[str], config: Config, scenarios: dict[str, Scenario]
) -> tuple[dict[str, Impact], list[str], dict[str, str], set[str]]:
    impacts: dict[str, Impact] = {}
    errors: list[str] = []
    exemptions_used: dict[str, str] = {}
    hit_rules: set[str] = set()

    for path in sorted(files):
        source_rules = [rule for rule in config.rules if matches(path, rule.source_globs)]
        test_rules = [rule for rule in config.rules if matches(path, rule.test_globs)]

        if matches(path, config.tracked_source_globs) and not source_rules:
            exemption = exemption_for(path, config)
            if exemption is None:
                errors.append(
                    f"unmapped behavioral source change: {path}. Add a QA impact rule or a documented narrow exemption."
                )
            else:
                exemptions_used[path] = exemption.reason

        for rule in source_rules:
            hit_rules.add(rule.identifier)
            for qa_id in rule.qa_ids:
                impact = impacts.setdefault(qa_id, Impact(set(), set(), set()))
                impact.source_files.add(path)
                impact.rules.add(rule.identifier)
        for rule in test_rules:
            hit_rules.add(rule.identifier)
            for qa_id in rule.qa_ids:
                impact = impacts.setdefault(qa_id, Impact(set(), set(), set()))
                impact.test_files.add(path)
                impact.rules.add(rule.identifier)

    # Defensive check for pure tests/matcher callers that bypass load_config.
    unknown = sorted(set(impacts) - set(scenarios))
    if unknown:
        errors.append("impact map produced unknown QA IDs: " + ", ".join(unknown))

    return impacts, errors, exemptions_used, hit_rules


def evidence_results(path: Path) -> dict[str, str]:
    if not path.is_file():
        return {}
    text = path.read_text(encoding="utf-8")
    if text.count(RESULTS_START) != 1 or text.count(RESULTS_END) != 1:
        return {}
    block = text.partition(RESULTS_START)[2].partition(RESULTS_END)[0]
    results: dict[str, str] = {}
    for line in block.splitlines():
        match = EVIDENCE_ROW_RE.match(line.strip())
        if match is not None:
            results[match.group(1)] = match.group(2)
    return results


def release_evidence_errors(
    version: str,
    impacts: dict[str, Impact],
    scenarios: dict[str, Scenario],
    config: Config,
) -> tuple[list[str], dict[str, str]]:
    manual_impacts = sorted(
        qa_id for qa_id in impacts if scenarios[qa_id].mode != "automated"
    )
    if not manual_impacts:
        return [], {}

    path = config.release_evidence_directory / f"{version}.md"
    if not path.is_file():
        return [f"release candidate {version} is missing {path.relative_to(ROOT)}"], {}
    results = evidence_results(path)
    missing = [qa_id for qa_id in manual_impacts if qa_id not in results]
    if missing:
        return [
            f"release evidence {path.relative_to(ROOT)} does not classify impacted QA IDs: {', '.join(missing)}"
        ], results
    return [], {qa_id: results[qa_id] for qa_id in manual_impacts}


def format_trigger(impact: Impact) -> str:
    parts: list[str] = []
    if impact.source_files:
        parts.append("source: " + ", ".join(sorted(impact.source_files)))
    if impact.test_files:
        parts.append("tests: " + ", ".join(sorted(impact.test_files)))
    return "; ".join(parts)


def markdown_report(
    base: str | None,
    files: set[str],
    impacts: dict[str, Impact],
    scenarios: dict[str, Scenario],
    exemptions_used: dict[str, str],
    hit_rules: set[str],
    candidate_version: str | None,
    candidate_results: dict[str, str],
) -> str:
    lines = ["## Behavioral QA impact traceability", ""]
    if base is None:
        lines.append("Configuration-only validation; no diff base was supplied.")
        return "\n".join(lines) + "\n"

    lines.append(f"Base: `{base}`")
    lines.append(f"Changed files considered: **{len(files)}**")
    lines.append(f"Triggered rule families: **{len(hit_rules)}**")
    lines.append(f"Impacted QA scenarios: **{len(impacts)}**")
    lines.append("")

    if impacts:
        lines.extend([
            "| QA ID | Mode | Scenario | Trigger |",
            "| --- | --- | --- | --- |",
        ])
        for qa_id in sorted(impacts):
            scenario = scenarios[qa_id]
            trigger = format_trigger(impacts[qa_id]).replace("|", "\\|")
            lines.append(
                f"| `{qa_id}` | `{scenario.mode}` | {scenario.scenario} | {trigger} |"
            )
    else:
        lines.append("No Behavioral QA scenario was impacted by this diff.")

    if candidate_version is not None:
        lines.extend(["", f"### Release candidate `{candidate_version}` evidence"])
        if candidate_results:
            lines.extend(["", "| Impacted manual/mixed ID | Evidence result |", "| --- | --- |"])
            for qa_id in sorted(candidate_results):
                lines.append(f"| `{qa_id}` | `{candidate_results[qa_id]}` |")
        else:
            lines.append("")
            lines.append("No impacted manual/mixed IDs required an evidence lookup.")

    if exemptions_used:
        lines.extend(["", "### Narrow exemptions used", ""])
        for path, reason in sorted(exemptions_used.items()):
            lines.append(f"- `{path}` — {reason}")

    return "\n".join(lines) + "\n"


def append_github_summary(report: str) -> None:
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if not path:
        return
    with open(path, "a", encoding="utf-8") as handle:
        handle.write(report)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--base",
        help="base commit/ref for diff-aware QA impact analysis; omit for configuration validation",
    )
    parser.add_argument(
        "--github-summary",
        action="store_true",
        help="append the impact report to GITHUB_STEP_SUMMARY when available",
    )
    args = parser.parse_args()

    try:
        config, scenarios = load_config()
        files: set[str] = set()
        impacts: dict[str, Impact] = {}
        errors: list[str] = []
        exemptions_used: dict[str, str] = {}
        hit_rules: set[str] = set()
        candidate_version: str | None = None
        candidate_results: dict[str, str] = {}

        if args.base:
            files = changed_files(args.base)
            impacts, errors, exemptions_used, hit_rules = evaluate_files(
                files, config, scenarios
            )
            before_version = version_at(args.base)
            after_version = current_version()
            if before_version != after_version:
                candidate_version = after_version
                evidence_errors, candidate_results = release_evidence_errors(
                    after_version, impacts, scenarios, config
                )
                errors.extend(evidence_errors)

        report = markdown_report(
            args.base,
            files,
            impacts,
            scenarios,
            exemptions_used,
            hit_rules,
            candidate_version,
            candidate_results,
        )
        if args.github_summary:
            append_github_summary(report)
    except (OSError, ValueError, RuntimeError, json.JSONDecodeError) as error:
        print(f"QA impact traceability error: {error}", file=sys.stderr)
        return 2

    if errors:
        print("QA impact traceability failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        print(
            "Update Scripts/qa-impact-rules.json or the version-specific release evidence truthfully; do not invent a QA pass.",
            file=sys.stderr,
        )
        return 1

    if args.base:
        print(
            f"QA impact traceability OK: {len(impacts)} scenario(s) impacted across {len(hit_rules)} rule family/families."
        )
        for qa_id in sorted(impacts):
            scenario = scenarios[qa_id]
            print(f"- {qa_id} [{scenario.mode}] {scenario.scenario}")
    else:
        print(
            f"QA impact traceability configuration OK: {len(scenarios)} Behavioral QA scenarios covered by {len(config.rules)} rule families."
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
