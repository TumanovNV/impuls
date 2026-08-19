#!/usr/bin/env python3
"""Require documentation review when contract-sensitive source lines change.

Standard-library only. The checker deliberately does not try to infer the full
meaning of Swift/Python: it identifies high-risk changed lines and requires the
canonical engineering document to travel in the same diff.
"""

from __future__ import annotations

import argparse
import fnmatch
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RULES_PATH = ROOT / "Scripts" / "documentation-guardian-rules.json"


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


def load_rules() -> list[dict]:
    data = json.loads(RULES_PATH.read_text(encoding="utf-8"))
    if data.get("schema_version") != 1:
        raise ValueError("documentation guardian rules schema_version must be 1")
    rules = data.get("rules")
    if not isinstance(rules, list) or not rules:
        raise ValueError("documentation guardian rules must be a non-empty list")

    seen: set[str] = set()
    for rule in rules:
        required = {"id", "description", "source_globs", "patterns", "required_docs_any"}
        missing = required - rule.keys()
        if missing:
            raise ValueError(f"rule {rule.get('id', '<unknown>')} missing: {', '.join(sorted(missing))}")
        if rule["id"] in seen:
            raise ValueError(f"duplicate guardian rule id: {rule['id']}")
        seen.add(rule["id"])
        if not rule["source_globs"] or not rule["patterns"] or not rule["required_docs_any"]:
            raise ValueError(f"rule {rule['id']} has an empty matcher or documentation route")
        for pattern in rule["patterns"]:
            re.compile(pattern)
        for doc in rule["required_docs_any"]:
            path = ROOT / doc
            if not path.is_file():
                raise ValueError(f"rule {rule['id']} points to missing doc: {doc}")
    return rules


def matches_path(path: str, globs: list[str]) -> bool:
    return any(fnmatch.fnmatch(path, pattern) for pattern in globs)


def changed_files(base: str) -> set[str]:
    return {
        line.strip()
        for line in git("diff", "--name-only", f"{base}...HEAD").splitlines()
        if line.strip()
    }


def changed_source_lines(base: str) -> list[tuple[str, str]]:
    patch = git("diff", "--unified=0", "--no-ext-diff", f"{base}...HEAD")
    output: list[tuple[str, str]] = []
    old_path: str | None = None
    new_path: str | None = None

    for line in patch.splitlines():
        if line.startswith("--- "):
            raw = line[4:].strip()
            old_path = None if raw == "/dev/null" else raw.removeprefix("a/")
            continue
        if line.startswith("+++ "):
            raw = line[4:].strip()
            new_path = None if raw == "/dev/null" else raw.removeprefix("b/")
            continue
        if line.startswith("diff --git "):
            old_path = None
            new_path = None
            continue
        if line.startswith("@@") or line.startswith("index "):
            continue
        if not (line.startswith("+") or line.startswith("-")):
            continue
        path = new_path or old_path
        if path is None:
            continue
        output.append((path, line[1:]))
    return output


def check(base: str | None, rules: list[dict]) -> list[str]:
    if base is None:
        return []

    files = changed_files(base)
    lines = changed_source_lines(base)
    errors: list[str] = []

    for rule in rules:
        compiled = [re.compile(pattern) for pattern in rule["patterns"]]
        hits: list[tuple[str, str]] = []
        for path, text in lines:
            if not matches_path(path, rule["source_globs"]):
                continue
            if any(pattern.search(text) for pattern in compiled):
                hits.append((path, text.strip()))

        if not hits:
            continue
        if any(doc in files for doc in rule["required_docs_any"]):
            continue

        examples = "; ".join(
            f"{path}: {text[:120]}" for path, text in hits[:3]
        )
        docs = " or ".join(rule["required_docs_any"])
        errors.append(
            f"{rule['id']}: {rule['description']}. Review/update {docs}. Hits: {examples}"
        )
    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--base",
        help="base commit/ref used for semantic diff checking; omitted means validate configuration only",
    )
    args = parser.parse_args()

    try:
        rules = load_rules()
        errors = check(args.base, rules)
    except (OSError, ValueError, RuntimeError, json.JSONDecodeError) as error:
        print(f"Documentation Guardian error: {error}", file=sys.stderr)
        return 2

    if errors:
        print("Documentation Guardian found contract changes without canonical documentation review:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        print(
            "Do not satisfy this with a meaningless Markdown touch. Establish the actual contract from code/tests and make the smallest truthful documentation update.",
            file=sys.stderr,
        )
        return 1

    mode = f"diff from {args.base}" if args.base else "configuration"
    print(f"Documentation Guardian OK: {len(rules)} rule families validated ({mode}).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
