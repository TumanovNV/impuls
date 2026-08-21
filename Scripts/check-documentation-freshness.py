#!/usr/bin/env python3
"""Detect canonical documentation that has fallen behind tracked implementation.

Unlike the diff-oriented Documentation Guardian, this check uses repository
history. A canonical document is fresh only when the latest commit touching its
tracked source is an ancestor of the latest commit touching the document and
its `last_reviewed` date is not older than that source change.

The `last_reviewed` half is skipped when the source and the document share their
latest commit: the two travelled together, so there is no history gap to measure,
and comparing a local-calendar commit day against a hand-written review date only
produces timezone false positives.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from datetime import date
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MANIFEST_PATH = ROOT / "Scripts" / "documentation-freshness.json"


def git(*args: str, allow_false: bool = False) -> tuple[int, str]:
    result = subprocess.run(
        ["git", *args],
        cwd=ROOT,
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode != 0 and not allow_false:
        raise RuntimeError(result.stderr.strip() or f"git {' '.join(args)} failed")
    return result.returncode, result.stdout.strip()


def frontmatter_last_reviewed(path: Path) -> date:
    lines = path.read_text(encoding="utf-8").splitlines()
    if not lines or lines[0].strip() != "---":
        raise ValueError(f"{path.relative_to(ROOT)} has no YAML frontmatter")
    for line in lines[1:]:
        if line.strip() == "---":
            break
        key, separator, value = line.partition(":")
        if separator and key.strip() == "last_reviewed":
            try:
                return date.fromisoformat(value.strip().strip("\"'"))
            except ValueError as error:
                raise ValueError(
                    f"{path.relative_to(ROOT)} has invalid last_reviewed"
                ) from error
    raise ValueError(f"{path.relative_to(ROOT)} has no last_reviewed field")


def load_manifest() -> list[dict]:
    data = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
    if data.get("schema_version") != 1:
        raise ValueError("documentation freshness schema_version must be 1")
    entries = data.get("entries")
    if not isinstance(entries, list) or not entries:
        raise ValueError("documentation freshness entries must be a non-empty list")

    seen: set[str] = set()
    for entry in entries:
        required = {"doc", "tracked_paths", "max_review_age_days"}
        missing = required - entry.keys()
        if missing:
            raise ValueError(
                f"freshness entry {entry.get('doc', '<unknown>')} missing: "
                + ", ".join(sorted(missing))
            )
        doc = entry["doc"]
        if doc in seen:
            raise ValueError(f"duplicate freshness doc: {doc}")
        seen.add(doc)
        doc_path = ROOT / doc
        if not doc_path.is_file():
            raise ValueError(f"freshness doc does not exist: {doc}")
        paths = entry["tracked_paths"]
        if not isinstance(paths, list) or not paths:
            raise ValueError(f"freshness entry {doc} has no tracked_paths")
        for tracked in paths:
            if not (ROOT / tracked).exists():
                raise ValueError(f"freshness entry {doc} tracks missing path: {tracked}")
        age = entry["max_review_age_days"]
        if not isinstance(age, int) or age <= 0:
            raise ValueError(f"freshness entry {doc} has invalid max_review_age_days")
    return entries


def latest_commit(paths: list[str]) -> tuple[str, date]:
    _, output = git("log", "-1", "--format=%H%x09%cs", "--", *paths)
    if not output or "\t" not in output:
        raise ValueError(f"no git history for tracked path(s): {', '.join(paths)}")
    sha, raw_date = output.split("\t", 1)
    return sha, date.fromisoformat(raw_date)


def is_ancestor(ancestor: str, descendant: str) -> bool:
    code, _ = git("merge-base", "--is-ancestor", ancestor, descendant, allow_false=True)
    if code == 0:
        return True
    if code == 1:
        return False
    raise RuntimeError(f"git merge-base failed for {ancestor} -> {descendant}")


def freshness_reasons(
    *,
    source_date: date,
    reviewed_date: date,
    source_is_ancestor_of_doc: bool,
    today: date,
    max_review_age_days: int,
    enforce_review_age: bool,
    source_is_doc_commit: bool = False,
) -> list[str]:
    reasons: list[str] = []
    if reviewed_date > today:
        reasons.append(f"last_reviewed {reviewed_date.isoformat()} is in the future")
    # A document whose latest commit *is* the latest commit of its tracked source
    # travelled with that source. There is no history gap left to measure, and the
    # date comparison below would answer a question that no longer exists: `%cs`
    # renders the committer's local calendar day, so a change written and reviewed
    # late on one day in a positive UTC offset commits as the next day and fails a
    # `last_reviewed` that was correct when it was written. That is exactly what
    # PR #75 hit. Same-commit review is the Documentation Guardian's territory —
    # it inspects the diff itself — and this checker exists for the other case:
    # source that moved on in a *later* commit than its canonical document.
    if source_date > reviewed_date and not source_is_doc_commit:
        reasons.append(
            f"tracked source changed on {source_date.isoformat()} after last_reviewed {reviewed_date.isoformat()}"
        )
    if not source_is_ancestor_of_doc:
        reasons.append("latest tracked source commit is newer than the latest document commit")
    if enforce_review_age and (today - reviewed_date).days > max_review_age_days:
        reasons.append(
            f"review age {(today - reviewed_date).days} days exceeds {max_review_age_days}-day policy"
        )
    return reasons


def check_entry(entry: dict, *, enforce_review_age: bool, today: date) -> list[str]:
    doc = entry["doc"]
    doc_path = ROOT / doc
    source_sha, source_date = latest_commit(entry["tracked_paths"])
    doc_sha, _ = latest_commit([doc])
    reviewed = frontmatter_last_reviewed(doc_path)
    reasons = freshness_reasons(
        source_date=source_date,
        reviewed_date=reviewed,
        source_is_ancestor_of_doc=is_ancestor(source_sha, doc_sha),
        today=today,
        max_review_age_days=entry["max_review_age_days"],
        enforce_review_age=enforce_review_age,
        source_is_doc_commit=source_sha == doc_sha,
    )
    if not reasons:
        return []
    prefix = f"{doc} (source {source_sha[:8]}, doc {doc_sha[:8]}): "
    return [prefix + reason for reason in reasons]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--enforce-review-age",
        action="store_true",
        help="also fail documents that exceed their periodic review-age policy",
    )
    args = parser.parse_args()

    try:
        entries = load_manifest()
        today = date.today()
        errors = [
            error
            for entry in entries
            for error in check_entry(
                entry,
                enforce_review_age=args.enforce_review_age,
                today=today,
            )
        ]
    except (OSError, ValueError, RuntimeError, json.JSONDecodeError) as error:
        print(f"Documentation freshness error: {error}", file=sys.stderr)
        return 2

    if errors:
        print("Documentation freshness check failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1

    mode = "source drift + review age" if args.enforce_review_age else "source drift"
    print(f"Documentation freshness OK: {len(entries)} canonical mappings checked ({mode}).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
