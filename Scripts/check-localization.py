#!/usr/bin/env python3
"""Localization completeness for the app's own string tables.

Every key the app looks up at runtime must exist in every shipped table, and
the tables must agree with each other.

The previous inline check matched `localized("literal")` only. That is most of
the call sites, but not all of them: `AppFeature` stores its keys and resolves
them through `localized(titleKey)`, so two reworded keys shipped in 1.4.11 and
1.4.12 with no table entry at all, and Russian users read them in English while
CI stayed green.

Resolving arbitrary indirection would need dataflow analysis. Instead this
refuses to guess: a `localized(...)` call whose argument is not a literal has to
be covered by a declared extractor below, or the check fails and says so. A new
indirection cannot be introduced silently.
"""
from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Sources"
RESOURCES = ROOT / "Resources"

# `localized(` that is a call, not the declaration in Strings.swift.
CALL_SITE = re.compile(r'(?<!func )\blocalized\(')
STRING_LITERAL = re.compile(r'"((?:[^"\\]|\\.)*)"')
TABLE_ENTRY = re.compile(r'^\s*"((?:[^"\\]|\\.)*)"\s*=', re.M)

# Files that reach `localized()` through a stored property, and the labelled
# string literals that become those keys. Keep each entry as narrow as the
# indirection it describes.
DECLARED_EXTRACTORS = {
    "Sources/Impuls/Services/AppFeatureCatalog.swift": (
        re.compile(r'\b(?:titleKey|detailKey|detail):\s*"((?:[^"\\]|\\.)*)"'),
        "AppFeature stores titleKey/detailKey and resolves them in `title`/`detail`.",
    ),
}


def unescape(raw: str) -> str:
    """Interpret the escapes both Swift literals and .strings entries use.

    Applied to code keys and table keys alike. The old check unescaped only the
    table side, so the first key containing a `\\n` would have been reported
    missing when it was present.
    """
    return raw.replace(r"\n", "\n").replace(r"\t", "\t").replace(r'\"', '"').replace(r"\\", "\\")


def swift_sources() -> list[pathlib.Path]:
    return sorted(SOURCES.rglob("*.swift"))


def argument_span(text: str, open_paren: int) -> str:
    """The source between `localized(` and its matching `)`.

    Scanned with a paren counter rather than a regex because an argument can
    itself be a call — `localized("%@ of %@", formatTime(media.duration))`.
    """
    depth = 0
    index = open_paren
    in_string = False
    escaped = False
    while index < len(text):
        character = text[index]
        if in_string:
            if escaped:
                escaped = False
            elif character == "\\":
                escaped = True
            elif character == '"':
                in_string = False
        elif character == '"':
            in_string = True
        elif character == "(":
            depth += 1
        elif character == ")":
            depth -= 1
            if depth == 0:
                return text[open_paren + 1:index]
        index += 1
    return ""


def keys_from_call(span: str) -> list[str]:
    """The lookup keys a single `localized(...)` call can contribute.

    A call that starts with a literal contributes that one key; the rest of the
    argument list is substitution values, not keys. Anything else — a ternary
    picking between two literals, for instance — contributes every literal it
    contains, because either branch can be the key.
    """
    literals = STRING_LITERAL.findall(span)
    if not literals:
        return []
    return [literals[0]] if span.lstrip().startswith('"') else literals


def collect_code_keys() -> tuple[set[str], list[str]]:
    keys: set[str] = set()
    problems: list[str] = []
    for path in swift_sources():
        text = path.read_text(encoding="utf-8")
        relative = path.relative_to(ROOT).as_posix()

        unresolved = 0
        for match in CALL_SITE.finditer(text):
            span = argument_span(text, match.end() - 1)
            found = keys_from_call(span)
            if found:
                keys |= {unescape(key) for key in found}
            else:
                unresolved += 1

        extractor = DECLARED_EXTRACTORS.get(relative)
        if extractor is not None:
            pattern, _ = extractor
            keys |= {unescape(key) for key in pattern.findall(text)}
        elif unresolved:
            # `localized()` reached through a value this check cannot see. Its
            # keys cannot be verified, so it has to be declared rather than
            # quietly skipped — that silence is how the 1.4.11 regression shipped.
            problems.append(
                f"{relative}: {unresolved} localized() call(s) take a value this check "
                f"cannot resolve. Add a narrow extractor to DECLARED_EXTRACTORS in "
                f"{pathlib.Path(__file__).name} so those keys are verified, or pass a literal."
            )

    # `AppFeature` stores an empty title key for every tab-backed feature and
    # resolves the tab's own title instead, so it never reaches a lookup.
    keys.discard("")
    return keys, problems


def collect_tables() -> dict[str, set[str]]:
    tables: dict[str, set[str]] = {}
    for table in sorted(RESOURCES.glob("*.lproj/Localizable.strings")):
        text = table.read_text(encoding="utf-8")
        tables[table.relative_to(ROOT).as_posix()] = {
            unescape(k) for k in TABLE_ENTRY.findall(text)
        }
    return tables


def main() -> int:
    code, problems = collect_code_keys()
    tables = collect_tables()

    if not tables:
        print("no Localizable.strings tables found under Resources/", file=sys.stderr)
        return 2

    failed = bool(problems)
    for problem in problems:
        print(problem)

    for name, keys in tables.items():
        missing = code - keys
        if missing:
            failed = True
            print(f"{name}: missing keys used in code:")
            for key in sorted(missing):
                print(f"    {key!r}")

    # Every table carries the same keys. A key present in English and absent in
    # Russian used to pass as long as it was also absent from code, which is
    # exactly how a reworded string leaves one translation behind.
    union = set().union(*tables.values())
    for name, keys in sorted(tables.items()):
        absent = union - keys
        if absent:
            failed = True
            print(f"{name}: keys present in another table but missing here:")
            for key in sorted(absent):
                print(f"    {key!r}")

    print(
        f"localization: {len(code)} keys used in code, "
        f"{len(tables)} tables, {len(union)} distinct keys"
    )
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
