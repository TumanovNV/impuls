#!/usr/bin/env python3
"""Answer "what must I read to work on this?" without loading the knowledge base.

The bootstrap problem this solves is measured rather than assumed: following the
previous root instructions literally meant ingesting roughly 101 KB of
documentation before opening a single Swift file, most of it irrelevant to a
local change.

This router reads the machine-readable routing sources itself and prints only
the route. It deliberately owns no knowledge of its own:

  Scripts/qa-impact-rules.json  source/test/QA mapping — the sole owner, already
                                CI-validated by check-qa-impact.py
  PROJECT-MANIFEST.json         agent_routing: domain name, documentation route
                                and the conditional owners a domain can escalate
                                to. Keyed by the same rule ids, so nothing is
                                copied between the two files.
  AI-INDEX.md                   fallback when a path routes nowhere

Adding a second source→test database was explicitly rejected: two copies drift,
and the drift is invisible until somebody trusts the wrong one.
"""

from __future__ import annotations

import argparse
import fnmatch
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "PROJECT-MANIFEST.json"
QA_RULES = ROOT / "Scripts" / "qa-impact-rules.json"


def load(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def tracked_files(base: str | None) -> list[str]:
    """Every tracked path, so a glob can be expanded without touching the disk
    tree. `--base` reads the tree at that ref instead, which is how a path that
    the working tree has already deleted or renamed still resolves."""
    argv = ["git", "ls-tree", "-r", "--name-only", base] if base else ["git", "ls-files"]
    try:
        out = subprocess.run(argv, cwd=ROOT, capture_output=True, text=True, check=True)
    except (subprocess.CalledProcessError, FileNotFoundError):
        return []
    return out.stdout.split()


def matches(path: str, globs: list[str]) -> bool:
    return any(fnmatch.fnmatch(path, g) for g in globs)


class Router:
    def __init__(self, base: str | None = None) -> None:
        self.manifest = load(MANIFEST)
        self.qa = load(QA_RULES)
        self.routing = self.manifest.get("agent_routing", {})
        self.domains = {d["id"]: d for d in self.routing.get("domains", [])}
        self.rules = {r["id"]: r for r in self.qa.get("rules", [])}
        self.tracked = tracked_files(base)

    # -- resolution ---------------------------------------------------------

    def domains_for(self, path: str) -> list[str]:
        """Every QA rule whose source globs claim this path.

        A path may belong to more than one — `FileToolsService.swift` is both
        Actions and Shelf file tools — and both are returned. Narrowing to one
        would hide an owner the change actually has.
        """
        return [rid for rid, rule in self.rules.items()
                if matches(path, rule.get("source_globs", []))]

    def resolve(self, targets: list[str]) -> dict:
        """A single route for however many paths or domain ids were given.

        Everything below is a UNION. An intersection was considered and is
        wrong: when one changed file touches networking and another touches
        persistence, the change needs *both* owners, and keeping only what they
        share would return neither.
        """
        domain_ids: list[str] = []
        unrouted: list[str] = []
        matched_paths: dict[str, list[str]] = {}

        for target in targets:
            if target in self.domains or target in self.rules:
                domain_ids.append(target)
                continue
            found = self.domains_for(target)
            if found:
                domain_ids.extend(found)
                matched_paths[target] = found
            else:
                unrouted.append(target)

        seen: set[str] = set()
        ordered = [d for d in domain_ids if not (d in seen or seen.add(d))]

        read_first: list[str] = []
        tests: list[str] = []
        qa_ids: list[str] = []
        conditional: list[dict] = []
        names: list[str] = []

        for rid in ordered:
            domain = self.domains.get(rid)
            rule = self.rules.get(rid, {})
            if domain:
                names.append(domain.get("name", rid))
                for doc in domain.get("read_first", []):
                    if doc not in read_first:
                        read_first.append(doc)
                for item in domain.get("conditional", []):
                    if item["doc"] not in {c["doc"] for c in conditional}:
                        conditional.append(item)
            else:
                names.append(rid)
            for glob in rule.get("test_globs", []):
                for f in self.tracked:
                    if fnmatch.fnmatch(f, glob) and f not in tests:
                        tests.append(f)
            for qid in rule.get("qa_ids", []):
                if qid not in qa_ids:
                    qa_ids.append(qid)

        # A conditional owner that is already required unconditionally is not a
        # conditional: listing it twice would invite re-reading it.
        conditional = [c for c in conditional if c["doc"] not in read_first]

        sources = [t for t in targets if t not in self.domains and t not in self.rules]
        return {
            "domains": ordered,
            "domain_names": names,
            "read_first": read_first,
            "sources": sources,
            "tests": tests,
            "qa_ids": qa_ids,
            "conditional": conditional,
            "unrouted": unrouted,
            "matched": matched_paths,
            "cross_domain": len(ordered) > 1,
            "fallback_doc": self.routing.get("fallback_doc", ""),
        }


# -- presentation -----------------------------------------------------------

NEVER_BY_DEFAULT = [
    "knowledge-base/00-project/pre-audit-baseline-1.4.12.md — explicit whole-repository audit only",
    "knowledge-base/00-project/project-status.md — only when the shipped baseline matters",
    "knowledge-base/10-ai/AI-INDEX.md — only when this router cannot resolve the task",
    "every other domain's module doc",
    "knowledge-base/11-history/** and docs/** handoffs — historical evidence, on demand",
]


def render(route: dict) -> str:
    out: list[str] = []
    if route["domains"]:
        out.append("DOMAIN: " + ", ".join(route["domain_names"]))
    else:
        out.append("DOMAIN: (unresolved)")

    if route["read_first"]:
        out.append("\nREAD FIRST:")
        out += [f"- {d}" for d in route["read_first"]]

    if route["sources"]:
        out.append("\nSOURCE:")
        out += [f"- {s}" for s in route["sources"]]

    if route["tests"]:
        out.append("\nTESTS:")
        out += [f"- {t}" for t in route["tests"]]

    if route["qa_ids"]:
        out.append("\nQA:")
        out.append("- " + ", ".join(route["qa_ids"]))

    if route["conditional"]:
        out.append("\nCONDITIONAL:")
        for c in route["conditional"]:
            out.append(f"- {c['doc']}")
            out.append(f"  trigger: {c['trigger']}")

    out.append("\nDO NOT LOAD BY DEFAULT:")
    out += [f"- {n}" for n in NEVER_BY_DEFAULT]

    out.append("\nNOTES:")
    if route["unrouted"]:
        out.append("- UNROUTED: " + ", ".join(route["unrouted"]))
        out.append(f"  fall back to {route['fallback_doc']}, and add a route for this path")
    if route["cross_domain"]:
        out.append("- ESCALATED: CROSS-DOMAIN CHANGE")
        out.append("  every domain above is affected; read each owner listed in READ FIRST")
        out.append("  and every trigger under CONDITIONAL that this diff actually meets.")
        out.append("  This is still a bounded route — it is not a reason to read the whole"
                   " knowledge base.")
    out.append("- The budget never outranks correctness: if the change turns out to cross a"
               " boundary not listed here, read that owner too.")
    return "\n".join(out)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Print the minimal documentation route for a path or domain.")
    parser.add_argument("targets", nargs="+", help="repository path(s) or domain id(s)")
    parser.add_argument("--json", action="store_true", dest="as_json",
                        help="machine-readable output")
    parser.add_argument("--base", help="resolve paths against this git ref (deleted/renamed)")
    args = parser.parse_args()

    route = Router(base=args.base).resolve(args.targets)
    if args.as_json:
        print(json.dumps(route, indent=2, ensure_ascii=False, sort_keys=True))
    else:
        print(render(route))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
