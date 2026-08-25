#!/usr/bin/env python3
"""Keep the agent bootstrap small and the routing table honest.

Three failures this guards against, each of which has actually happened to this
repository or was measured on it:

  * the root instructions grow back into an encyclopedia, one reasonable
    paragraph at a time, until a local task costs ~100 KB again;
  * PROJECT-MANIFEST.json accumulates implementation detail and stops being a
    routing map;
  * a route points at a document that has been renamed or deleted, so the
    router confidently sends an agent nowhere;
  * a new QA rule appears with no documentation route, so the router answers
    `UNROUTED` for a path CI already considers owned — the checks below compare
    the two id sets in *both* directions, because only checking that every route
    has a rule leaves exactly this hole;
  * a route names an agent-specific rule file. `Scripts/agent-context.py` is
    generic and is read by more than one agent; `.claude/rules/*.md` already
    load themselves from their own `paths:` frontmatter, so routing to them
    would both duplicate that and send other agents into another agent's config.

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
#
# The review that separated documentation domains from QA overlays spent part of
# that headroom (10,395 bytes) explaining how to read the router's output, which
# is the one thing a bootstrap file cannot delegate. The ceiling deliberately did
# not move with it: the remaining margin is small on purpose, and the next
# addition should displace something rather than be appended.
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

ALLOWED_ROUTING_KEYS = {"schema", "role", "fallback_doc", "document_routes", "domains"}
ALLOWED_DOC_ROUTE_KEYS = {"id", "name", "globs", "globs_ref", "read_first",
                          "read_first_ref", "reason", "conditional"}
ALLOWED_DOMAIN_KEYS = {"id", "name", "route_role", "read_first", "conditional",
                       "overlay_reason"}

# Routes name canonical project documentation. An agent's own rule files are
# that agent's concern — see the module docstring.
AGENT_PRIVATE_PREFIXES = (".claude/", ".codex/", ".github/copilot", ".cursor/")


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
        role = domain.get("route_role")
        if role not in ("primary", "overlay"):
            errors.append(
                f"agent_routing domain {did!r}: route_role must be 'primary' or 'overlay', "
                f"got {role!r}. A QA rule is not automatically a documentation domain."
            )
        elif role == "overlay":
            # An overlay claims paths whose documentation belongs to somebody
            # else. Letting it carry a read_first is precisely the defect this
            # role exists to prevent.
            if domain.get("read_first"):
                errors.append(
                    f"agent_routing domain {did!r} is an overlay but declares read_first "
                    f"{domain['read_first']}. An overlay contributes tests and QA IDs only; "
                    "put the real owner under conditional with a trigger."
                )
            if not domain.get("overlay_reason"):
                errors.append(
                    f"agent_routing domain {did!r}: an overlay must state overlay_reason — "
                    "why its paths are verified here but documented elsewhere"
                )
        elif not domain.get("read_first"):
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

        for doc in list(domain.get("read_first", [])) + [
                i.get("doc", "") for i in domain.get("conditional", [])]:
            if doc.startswith(AGENT_PRIVATE_PREFIXES):
                errors.append(
                    f"agent_routing domain {did!r} routes to an agent-specific rule file: {doc}. "
                    "Scripts/agent-context.py is generic; route to the canonical project "
                    "document and let each agent load its own path-scoped rules."
                )

    check_route_completeness(errors, routing, qa_ids)
    check_document_routes(errors, manifest, routing, qa_ids)


def check_document_routes(errors: list[str], manifest: dict, routing: dict,
                          qa_ids: set[str]) -> None:
    """A document route says who documents a set of paths, and nothing else.

    The failure it must not be allowed to become is a second source/test/QA
    database. `Scripts/qa-impact-rules.json` owns that, and the way a duplicate
    starts is somebody adding `test_globs` here "just for this one path" — so the
    key allowlist rejects it outright rather than warning about it.

    The other rule is that these entries do not copy facts the manifest already
    holds: `globs_ref` and `read_first_ref` dereference into the manifest, and a
    ref that stops resolving is an error rather than a silently empty route.
    """
    router = load_router().Router()
    routes = routing.get("document_routes", [])
    seen: set[str] = set()

    for route in routes:
        rid = route.get("id", "")
        unknown = set(route) - ALLOWED_DOC_ROUTE_KEYS
        if unknown:
            errors.append(
                f"document_route {rid!r}: unknown key(s) {sorted(unknown)}. A document "
                "route carries documentation only — tests and QA IDs belong to "
                "Scripts/qa-impact-rules.json and must not be duplicated here."
            )
        if rid in seen:
            errors.append(f"document_routes has a duplicate id: {rid}")
        seen.add(rid)
        if rid in qa_ids:
            errors.append(
                f"document_route {rid!r} collides with a QA rule id. They are different "
                "namespaces on purpose; a shared id makes the router ambiguous."
            )
        if not route.get("reason"):
            errors.append(f"document_route {rid!r}: state a reason — why these paths are "
                          "documented here rather than by a QA domain")

        if ("globs" in route) == ("globs_ref" in route):
            errors.append(f"document_route {rid!r}: set exactly one of globs / globs_ref")
        if ("read_first" in route) == ("read_first_ref" in route):
            errors.append(
                f"document_route {rid!r}: set exactly one of read_first / read_first_ref")

        for key in ("globs_ref", "read_first_ref"):
            if key not in route:
                continue
            try:
                router.deref(route[key])
            except (KeyError, IndexError, TypeError, ValueError):
                errors.append(
                    f"document_route {rid!r}: {key} {route[key]!r} does not resolve in "
                    "PROJECT-MANIFEST.json"
                )

        try:
            globs = router.route_globs(route)
            docs = router.route_docs(route)
        except (KeyError, IndexError, TypeError, ValueError):
            continue

        if not globs:
            errors.append(f"document_route {rid!r} matches no paths")
        if not docs:
            errors.append(f"document_route {rid!r} names no canonical document")
        for doc in docs + [i.get("doc", "") for i in route.get("conditional", [])]:
            if not (ROOT / doc).is_file():
                errors.append(f"document_route {rid!r}: missing document: {doc}")
            if doc.startswith(AGENT_PRIVATE_PREFIXES):
                errors.append(
                    f"document_route {rid!r} routes to an agent-specific rule file: {doc}")
        for item in route.get("conditional", []):
            if not item.get("trigger"):
                errors.append(
                    f"document_route {rid!r}: conditional {item.get('doc')} has no trigger")

        # A route nobody can reach is worse than no route: it looks like coverage.
        if not any(fnmatch.fnmatch(f, g) for g in globs for f in router.tracked):
            errors.append(
                f"document_route {rid!r} matches no tracked file, so it is dead routing")

    # Overlapping routes would make the answer depend on declaration order.
    for path in router.tracked:
        hits = [r.get("id", "") for r in routes
                if any(fnmatch.fnmatch(path, g) for g in router.route_globs(r))]
        if len(hits) > 1:
            errors.append(
                f"{path} matches more than one document_route: {hits}. Exactly one "
                "document owner per path, or the answer depends on declaration order."
            )
            break


def check_route_completeness(errors: list[str], routing: dict, qa_ids: set[str]) -> None:
    """Both directions, because one direction is a hole.

    Every route already had to name a real QA rule. Nothing required the reverse:
    a new rule in `Scripts/qa-impact-rules.json` could ship with tests and QA IDs
    and no documentation route at all, and the router would answer `UNROUTED` for
    a path that CI treats as fully owned — with CI green the whole time. That is
    the caveat this repository shipped with in 1.4.16 and it is closed by set
    equality, not by good intentions.

    There is currently no QA rule that should legitimately have no route, so no
    exemption mechanism exists. If one ever does, add an explicit
    `router_exemptions` list of `{id, reason}` here rather than loosening the
    comparison — a silent exception is how the hole reopens.
    """
    routed = {d.get("id", "") for d in routing.get("domains", [])}
    missing = sorted(qa_ids - routed)
    if missing:
        errors.append(
            "Scripts/qa-impact-rules.json rule(s) with no agent_routing domain: "
            f"{missing}. Every QA rule is routable: add a domain for each id above "
            "(route_role 'primary' with its canonical document, or 'overlay' with an "
            "overlay_reason), so the router cannot answer UNROUTED for a path CI "
            "already considers owned."
        )
    extra = sorted(routed - qa_ids)
    if extra:
        errors.append(
            f"agent_routing domain(s) with no matching QA rule id: {extra}"
        )


# The files that tell an agent how to start. Every one of them has, at some
# point, carried its own version of "read A, then B, then C" — which is how the
# repository ended up with a router *and* three surviving preload chains that
# contradicted it.
AI_ENTRYPOINTS = (
    "AGENTS.md",
    "CLAUDE.md",
    "README.ru.md",
    "knowledge-base/10-ai/AI-INDEX.md",
    "knowledge-base/10-ai/agent-rules.md",
    "knowledge-base/10-ai/repository-map.md",
    "knowledge-base/12-reference/README.md",
    "knowledge-base/12-reference/project-manifest.md",
)

ROUTER_INVOCATION = "Scripts/agent-context.py"

# Names that used to be links in the mandatory chain. An arrow from one of these
# to another is the shape of the contradiction, whatever the surrounding prose
# says.
CHAIN_TOKENS = ("AGENTS.md", "PROJECT-MANIFEST.json", "AI-INDEX.md", "AI Index")
ARROWS = ("\u2192", "->")
ARROW_WINDOW = 60


def check_single_workflow(errors: list[str]) -> None:
    """One bootstrap workflow, stated the same way everywhere.

    Two deterministic checks, and deliberately no attempt to read the prose:

      * every AI entrypoint names the router. If a file explains how to start and
        never mentions `Scripts/agent-context.py`, it is describing some other
        workflow.
      * no entrypoint contains an arrow leading from one former chain link to
        another. `AGENTS.md -> PROJECT-MANIFEST.json -> AI-INDEX.md` is a literal
        shape, not a semantic judgement, so this cannot misfire on a paragraph
        that merely mentions two of the files.

    What this cannot catch is a chain written in words with no arrow at all. That
    is stated rather than papered over: the check narrows the failure, it does
    not claim to close it.
    """
    for rel in AI_ENTRYPOINTS:
        path = ROOT / rel
        if not path.is_file():
            errors.append(f"{rel}: AI entrypoint is missing")
            continue
        text = path.read_text(encoding="utf-8")

        if ROUTER_INVOCATION not in text:
            errors.append(
                f"{rel} explains how to start but never names {ROUTER_INVOCATION}. "
                "There is one bootstrap workflow: AGENTS.md -> the router -> the owner "
                "it returns -> implementation and tests."
            )

        for arrow in ARROWS:
            start = 0
            while (hit := text.find(arrow, start)) != -1:
                start = hit + len(arrow)
                before = text[max(0, hit - ARROW_WINDOW):hit]
                after = text[start:start + ARROW_WINDOW]
                left = {t for t in CHAIN_TOKENS if t in before}
                right = {t for t in CHAIN_TOKENS if t in after}
                if left and right - left:
                    errors.append(
                        f"{rel} still chains bootstrap entrypoints: "
                        f"{sorted(left)} -> {sorted(right - left)}. The manifest is the "
                        "router's input and AI-INDEX.md is its fallback; neither is a "
                        "step an agent performs before routing."
                    )


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

    # The same round trip for document routes: a declared owner that no path
    # actually reaches is documentation nobody will ever be sent to.
    for route in router.doc_routes:
        rid = route["id"]
        globs = router.route_globs(route)
        sample = next((f for f in tracked
                       if any(fnmatch.fnmatch(f, g) for g in globs)), None)
        if sample is None:
            continue
        resolved = router.resolve([sample])
        if rid not in resolved["primary_owners"]:
            errors.append(f"path {sample} does not route back to document route {rid}")
        for doc in router.route_docs(route):
            if doc not in resolved["read_first"]:
                errors.append(f"document route {rid}: {sample} does not reach {doc}")
        if resolved["qa_ids"] and not resolved["domains"]:
            errors.append(f"document route {rid} invented QA IDs for {sample}")


def main() -> int:
    errors: list[str] = []
    check_bootstrap_budget(errors)
    check_manifest_schema(errors)
    check_single_workflow(errors)
    check_router_resolves(errors)

    if errors:
        print("Agent context validation failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1

    total = sum(len((ROOT / n).read_bytes()) for n in BOOTSTRAP_FILES)
    manifest = read_json("PROJECT-MANIFEST.json")
    routing = manifest["agent_routing"]
    print(
        f"Agent context OK: root bootstrap {total} B of {BOOTSTRAP_BUDGET_BYTES} budget; "
        f"{len(routing['domains'])} routing domains and "
        f"{len(routing.get('document_routes', []))} document routes resolve."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
