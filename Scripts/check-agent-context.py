#!/usr/bin/env python3
"""Keep the agent bootstrap small and the routing table honest.

Three failures this guards against, each of which has actually happened to this
repository or was measured on it:

  * the root instructions grow back into an encyclopedia, one reasonable
    paragraph at a time, until a local task costs ~100 KB again;
  * PROJECT-MANIFEST.json accumulates implementation detail and stops being a
    routing map;
  * a route points at a document that has been renamed or deleted, so the
    router confidently sends an agent nowhere.

Deliberately **not** here: any attempt to detect semantic duplication by
counting keywords or comparing paragraphs. That heuristic cannot tell a
duplicated rule from a legitimate cross-reference, and a guard that cries wolf
gets silenced. Ownership is enforced by routing metadata and by these
deterministic checks instead.
"""

from __future__ import annotations

import fnmatch
import importlib.util
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# Ceiling for the two files every agent reads before anything else.
#
# Not a target picked in advance: the shell was written first, reviewed for
# content, and measured at 9,665 bytes. The ceiling is that figure plus about
# 15% of headroom, rounded — enough for a genuine new invariant or route,
# not enough to quietly re-absorb a subsystem contract.
BOOTSTRAP_FILES = ("AGENTS.md", "CLAUDE.md")
BOOTSTRAP_BUDGET_BYTES = 11_200

# Routing-oriented keys only. A new key is not forbidden — it is a review
# prompt: add it here once it is genuinely routing, or keep the detail in its
# canonical document.
ALLOWED_MANIFEST_KEYS = {
    "schema_version", "manifest_role", "source_of_truth_rule", "product",
    "knowledge_entrypoints", "modules", "presentation_surfaces", "network_owners",
    "permission_domains", "persistence", "performance", "security", "dependencies",
    "release", "history", "web_and_collector", "operations_boundary", "validation",
    "agent_routing",
}

ALLOWED_ROUTING_KEYS = {"schema", "role", "fallback_doc", "domains"}
ALLOWED_DOMAIN_KEYS = {"id", "name", "read_first", "conditional"}


def load_router():
    """The router is a hyphenated script, so it is loaded by path rather than
    imported. Both the checker and the tests use this, so there is one way in."""
    spec = importlib.util.spec_from_file_location(
        "agent_context", ROOT / "Scripts" / "agent-context.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def read_json(rel: str) -> dict:
    return json.loads((ROOT / rel).read_text(encoding="utf-8"))


def check_bootstrap_budget(errors: list[str]) -> None:
    total = 0
    for name in BOOTSTRAP_FILES:
        path = ROOT / name
        if not path.is_file():
            errors.append(f"{name}: missing bootstrap file")
            continue
        total += len(path.read_bytes())
    if total > BOOTSTRAP_BUDGET_BYTES:
        errors.append(
            f"root bootstrap is {total} bytes, above the {BOOTSTRAP_BUDGET_BYTES} budget. "
            "Move the detail to its canonical owner and leave a one-line route, or raise "
            "the budget deliberately with a reason."
        )


def check_manifest_schema(errors: list[str]) -> None:
    manifest = read_json("PROJECT-MANIFEST.json")
    unknown = set(manifest) - ALLOWED_MANIFEST_KEYS
    if unknown:
        errors.append(
            f"PROJECT-MANIFEST.json has non-routing top-level key(s): {sorted(unknown)}. "
            "The manifest is routing-only; implementation facts belong in the canonical document."
        )

    routing = manifest.get("agent_routing")
    if not isinstance(routing, dict):
        errors.append("PROJECT-MANIFEST.json is missing the agent_routing block")
        return
    unknown = set(routing) - ALLOWED_ROUTING_KEYS
    if unknown:
        errors.append(f"agent_routing has unknown key(s): {sorted(unknown)}")

    fallback = routing.get("fallback_doc", "")
    if not (ROOT / fallback).is_file():
        errors.append(f"agent_routing.fallback_doc does not exist: {fallback}")

    qa_ids = {r["id"] for r in read_json("Scripts/qa-impact-rules.json")["rules"]}
    seen: set[str] = set()
    for domain in routing.get("domains", []):
        unknown = set(domain) - ALLOWED_DOMAIN_KEYS
        if unknown:
            errors.append(f"agent_routing domain {domain.get('id')!r}: unknown key(s) {sorted(unknown)}")
        did = domain.get("id", "")
        if did in seen:
            errors.append(f"agent_routing has a duplicate domain id: {did}")
        seen.add(did)
        # The back-link that keeps source/test/QA mapping in one place.
        if did not in qa_ids:
            errors.append(
                f"agent_routing domain {did!r} does not match a rule id in "
                "Scripts/qa-impact-rules.json, so the router cannot reach its sources or tests"
            )
        if not domain.get("read_first"):
            errors.append(f"agent_routing domain {did!r} has no read_first document")
        for doc in domain.get("read_first", []):
            if not (ROOT / doc).is_file():
                errors.append(f"agent_routing domain {did!r}: read_first missing: {doc}")
        conditional_docs: set[str] = set()
        for item in domain.get("conditional", []):
            doc, trigger = item.get("doc", ""), item.get("trigger", "")
            if not (ROOT / doc).is_file():
                errors.append(f"agent_routing domain {did!r}: conditional missing: {doc}")
            if not trigger:
                errors.append(f"agent_routing domain {did!r}: conditional {doc} has no trigger")
            if doc in conditional_docs:
                errors.append(f"agent_routing domain {did!r}: duplicate conditional route {doc}")
            conditional_docs.add(doc)


def check_router_resolves(errors: list[str]) -> None:
    """Every declared domain must actually resolve, and a representative path
    from each must reach it. A route nobody can reach is worse than no route."""
    router = load_router().Router()
    tracked = router.tracked
    for domain in router.routing.get("domains", []):
        did = domain["id"]
        route = router.resolve([did])
        if did not in route["domains"]:
            errors.append(f"router cannot resolve declared domain: {did}")
            continue
        globs = router.rules.get(did, {}).get("source_globs", [])
        sample = next((f for f in tracked if any(fnmatch.fnmatch(f, g) for g in globs)), None)
        if sample is None:
            errors.append(f"domain {did!r} has no tracked source matching its qa-impact globs")
            continue
        if did not in router.resolve([sample])["domains"]:
            errors.append(f"path {sample} does not route back to its domain {did}")


def main() -> int:
    errors: list[str] = []
    check_bootstrap_budget(errors)
    check_manifest_schema(errors)
    check_router_resolves(errors)

    if errors:
        print("Agent context validation failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1

    total = sum(len((ROOT / n).read_bytes()) for n in BOOTSTRAP_FILES)
    manifest = read_json("PROJECT-MANIFEST.json")
    print(
        f"Agent context OK: root bootstrap {total} B of {BOOTSTRAP_BUDGET_BYTES} budget; "
        f"{len(manifest['agent_routing']['domains'])} routing domains resolve."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
