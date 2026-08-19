#!/usr/bin/env python3
"""Validate the Markdown-first Impuls engineering knowledge base.

Standard-library only by design: the documentation check must not add a project
dependency merely to prove that documentation is internally consistent.
"""

from __future__ import annotations

import os
import re
import sys
from pathlib import Path
from urllib.parse import unquote

ROOT = Path(__file__).resolve().parents[1]
KNOWLEDGE_BASE = ROOT / "knowledge-base"
DOCUMENTATION_BASELINE = "1.3"
REQUIRED_FRONTMATTER = {
    "title",
    "type",
    "status",
    "documentation_version",
    "app_version",
    "last_reviewed",
    "tags",
}
BASELINE_DOCUMENTS = {
    Path("knowledge-base/INDEX.md"),
    Path("knowledge-base/00-project/project-status.md"),
    Path("knowledge-base/10-ai/AI-INDEX.md"),
    Path("knowledge-base/12-reference/README.md"),
    Path("knowledge-base/13-qa/README.md"),
}
LINK_RE = re.compile(r"!?\[[^\]]*\]\(([^)]+)\)")
DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
DOC_VERSION_RE = re.compile(r"^\d+\.\d+$")


def current_app_version() -> str:
    version_file = ROOT / "Scripts" / "version"
    for line in version_file.read_text(encoding="utf-8").splitlines():
        if line.startswith("VERSION="):
            value = line.partition("=")[2].strip()
            if value:
                return value
    raise ValueError("Scripts/version does not contain VERSION=")


def frontmatter(path: Path, text: str) -> dict[str, str] | None:
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        return None
    try:
        end = next(i for i in range(1, len(lines)) if lines[i].strip() == "---")
    except StopIteration:
        raise ValueError(f"{path.relative_to(ROOT)}: frontmatter is not closed")

    result: dict[str, str] = {}
    for line in lines[1:end]:
        if not line.strip() or line.lstrip().startswith("#") or ":" not in line:
            continue
        key, _, value = line.partition(":")
        result[key.strip()] = value.strip().strip("\"'")
    return result


def visible_markdown_lines(path: Path, text: str) -> list[tuple[int, str]]:
    """Return prose lines while validating fenced-code/Mermaid closure."""
    output: list[tuple[int, str]] = []
    fence: str | None = None
    fence_started = 0
    for number, line in enumerate(text.splitlines(), start=1):
        stripped = line.lstrip()
        if stripped.startswith("```"):
            if fence is None:
                fence = stripped[3:].strip() or "plain"
                fence_started = number
            else:
                fence = None
                fence_started = 0
            continue
        if fence is None:
            output.append((number, line))
    if fence is not None:
        raise ValueError(
            f"{path.relative_to(ROOT)}:{fence_started}: unclosed fenced block ({fence})"
        )
    return output


def normalize_link_target(raw: str) -> str:
    target = raw.strip()
    if target.startswith("<") and ">" in target:
        target = target[1 : target.index(">")]
    else:
        target = target.split(maxsplit=1)[0]
    return unquote(target)


def validate_link(source: Path, line_number: int, raw_target: str, errors: list[str]) -> None:
    target = normalize_link_target(raw_target)
    lower = target.lower()
    if not target or target.startswith("#") or lower.startswith(
        ("http://", "https://", "mailto:", "tel:", "data:", "x-apple-systempreferences:")
    ):
        return

    target = target.split("#", 1)[0].split("?", 1)[0]
    if not target:
        return

    candidate = (ROOT / target.lstrip("/")) if target.startswith("/") else (source.parent / target)
    resolved = candidate.resolve(strict=False)
    try:
        inside_repo = os.path.commonpath([str(ROOT.resolve()), str(resolved)]) == str(ROOT.resolve())
    except ValueError:
        inside_repo = False
    if not inside_repo:
        errors.append(
            f"{source.relative_to(ROOT)}:{line_number}: link escapes repository: {raw_target}"
        )
        return
    if not resolved.exists():
        errors.append(
            f"{source.relative_to(ROOT)}:{line_number}: broken local link: {raw_target}"
        )


def main() -> int:
    if not KNOWLEDGE_BASE.is_dir():
        print("knowledge-base directory is missing", file=sys.stderr)
        return 1

    try:
        app_version = current_app_version()
    except ValueError as error:
        print(error, file=sys.stderr)
        return 1

    errors: list[str] = []
    documents = sorted(KNOWLEDGE_BASE.rglob("*.md"))
    for path in documents:
        relative = path.relative_to(ROOT)
        text = path.read_text(encoding="utf-8")

        try:
            metadata = frontmatter(path, text)
        except ValueError as error:
            errors.append(str(error))
            metadata = None

        if relative != Path("knowledge-base/README.md"):
            if metadata is None:
                errors.append(f"{relative}: YAML frontmatter is required")
            else:
                missing = REQUIRED_FRONTMATTER - metadata.keys()
                if missing:
                    errors.append(f"{relative}: missing frontmatter keys: {', '.join(sorted(missing))}")
                if metadata.get("documentation_version") and not DOC_VERSION_RE.fullmatch(
                    metadata["documentation_version"]
                ):
                    errors.append(f"{relative}: documentation_version must be N.N")
                if metadata.get("last_reviewed") and not DATE_RE.fullmatch(metadata["last_reviewed"]):
                    errors.append(f"{relative}: last_reviewed must be YYYY-MM-DD")
                if relative in BASELINE_DOCUMENTS:
                    if metadata.get("app_version") != app_version:
                        errors.append(
                            f"{relative}: baseline app_version {metadata.get('app_version')!r} "
                            f"does not match Scripts/version {app_version!r}"
                        )
                    if metadata.get("documentation_version") != DOCUMENTATION_BASELINE:
                        errors.append(
                            f"{relative}: baseline documentation_version "
                            f"{metadata.get('documentation_version')!r} does not match "
                            f"{DOCUMENTATION_BASELINE!r}"
                        )

        try:
            lines = visible_markdown_lines(path, text)
        except ValueError as error:
            errors.append(str(error))
            lines = []

        for line_number, line in lines:
            for match in LINK_RE.finditer(line):
                validate_link(path, line_number, match.group(1), errors)

    if errors:
        print("Knowledge-base validation failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1

    print(
        f"Knowledge base OK: {len(documents)} Markdown files, "
        f"documentation {DOCUMENTATION_BASELINE}, baseline Impuls {app_version}, "
        "local links and fenced diagrams valid."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
