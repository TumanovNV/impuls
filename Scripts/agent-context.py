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
  PROJECT-MANIFEST.json         agent_routing: domains keyed by the same rule ids,
                                plus document_routes, plus the conditional owners
                                each can escalate to. Nothing is copied between
                                the two files.
  AI-INDEX.md                   fallback when a path routes nowhere

Adding a second source→test database was explicitly rejected: two copies drift,
and the drift is invisible until somebody trusts the wrong one.

A QA rule and a documentation domain are not the same thing, and conflating them
produced a real defect: `appearance-accessibility` claims `Sources/Impuls/UI/*.swift`
because every pane inherits the panel's appearance QA, so every pane also inherited
a canonical document that had nothing to do with it, and every pane change reported
itself as cross-domain. `route_role` separates the two:

  primary   owns the canonical document for its paths, and counts towards
            cross-domain escalation
  overlay   contributes tests and Behavioral QA IDs to paths that belong to
            somebody else. No read_first, and never a reason to escalate. Its
            real owners are offered as conditionals with triggers instead.

`route_role` is a property of the whole rule, which is not fine enough on its own.
`SettingsWindow.swift` is claimed by three rules — appearance, interface language,
version statistics — because one window hosts every setting. Two of those are
primary domains elsewhere, so an ordinary Settings edit reported itself as a
localization-plus-telemetry cross-domain change. `document_routes` fixes that at
the level the question is actually asked, the path:

  a path with a document route takes its canonical owner from that route, and
  every QA rule claiming the path drops to verification for it.

The same mechanism gives an owner to paths that have no QA rule and should not be
given one. `Resources/*.lproj/Localizable.strings` and `Scripts/version` are where
localization and release work usually starts, but neither is behavioural Swift
source; adding them to `qa-impact-rules.json` to satisfy the router would invent a
behavioural owner. A document route carries documentation and nothing else — no
test globs, no QA IDs — and where the manifest already knows the path or the
document, the entry points at it instead of copying it.

Routes name canonical project documentation only. Agent-specific rule files —
`.claude/rules/*.md` and anything like them — are the agent's own concern: Claude
loads them from their own `paths:` frontmatter, and no other agent should be told
to read them.
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

PRIMARY = "primary"
OVERLAY = "overlay"
ROUTE_ROLES = (PRIMARY, OVERLAY)


def load(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def tracked_files() -> list[str]:
    """Every tracked path, so a test glob can be expanded without walking the disk.

    Deliberately the working tree only. An earlier `--base <ref>` option read the
    file list at another ref and advertised that it resolved deleted and renamed
    paths — which it did not: the routing tables themselves were still read from
    the working tree, so a file renamed on the branch was looked up in the branch's
    rules under its old name and could answer UNROUTED. Rather than half-implement
    a historical mode, the option is gone; resolving a route as of another commit
    means checking that commit out.
    """
    try:
        out = subprocess.run(["git", "ls-files"], cwd=ROOT,
                             capture_output=True, text=True, check=True)
    except (subprocess.CalledProcessError, FileNotFoundError):
        return []
    return out.stdout.split()


def matches(path: str, globs: list[str]) -> bool:
    return any(fnmatch.fnmatch(path, g) for g in globs)


class Router:
    def __init__(self) -> None:
        self.manifest = load(MANIFEST)
        self.qa = load(QA_RULES)
        self.routing = self.manifest.get("agent_routing", {})
        self.domains = {d["id"]: d for d in self.routing.get("domains", [])}
        self.rules = {r["id"]: r for r in self.qa.get("rules", [])}
        self.doc_routes = self.routing.get("document_routes", [])
        self.tracked = tracked_files()

    # -- manifest references ------------------------------------------------

    def deref(self, dotted: str):
        """Resolve `product.localization_doc` or `release.canonical_docs.0`
        against the manifest, so a route points at a fact the manifest already
        owns instead of holding a second copy of it."""
        node = self.manifest
        for part in dotted.split("."):
            if isinstance(node, list):
                node = node[int(part)]
            else:
                node = node[part]
        return node

    def route_globs(self, route: dict) -> list[str]:
        if "globs_ref" in route:
            value = self.deref(route["globs_ref"])
            return value if isinstance(value, list) else [value]
        return route.get("globs", [])

    def route_docs(self, route: dict) -> list[str]:
        if "read_first_ref" in route:
            value = self.deref(route["read_first_ref"])
            return value if isinstance(value, list) else [value]
        return route.get("read_first", [])

    def document_route_for(self, path: str) -> dict | None:
        for route in self.doc_routes:
            if matches(path, self.route_globs(route)):
                return route
        return None

    # -- resolution ---------------------------------------------------------

    def role_of(self, rid: str) -> str:
        """A rule with no routing entry is treated as primary-but-undeclared:
        the completeness guard already fails that case loudly, and silently
        demoting it to an overlay here would hide the missing route."""
        return self.domains.get(rid, {}).get("route_role", PRIMARY)

    def domains_for(self, path: str) -> list[str]:
        """Every QA rule whose source globs claim this path.

        A path may belong to more than one — `FileToolsService.swift` is both
        Actions and Shelf file tools — and both are returned. Narrowing to one
        would hide an owner the change actually has.
        """
        return [rid for rid, rule in self.rules.items()
                if matches(path, rule.get("source_globs", []))]

    def claims_for(self, path: str) -> dict:
        """Who owns this ONE path, before anything is unioned.

        Documentation ownership and QA membership are answered separately, because
        they are separate questions and a file can honestly have three of the
        second and one of the first.
        """
        route = self.document_route_for(path)
        qa = self.domains_for(path)
        if route is not None:
            # The route is the documentation owner; every rule that also claims
            # this path is verifying it, not documenting it.
            return {"doc_route": route, "primary": [], "overlay": qa, "qa": qa}
        return {
            "doc_route": None,
            "primary": [r for r in qa if self.role_of(r) != OVERLAY],
            "overlay": [r for r in qa if self.role_of(r) == OVERLAY],
            "qa": qa,
        }

    def resolve(self, targets: list[str]) -> dict:
        """A single route for however many paths or domain ids were given.

        Everything below is a UNION. An intersection was considered and is
        wrong: when one changed file touches networking and another touches
        persistence, the change needs *both* owners, and keeping only what they
        share would return neither.

        The union is taken over per-path answers, not over raw rule matches, so a
        rule demoted for one path stays primary for another. Editing
        `SettingsWindow.swift` and `AppLanguageService.swift` together still gets
        the localization owner — from the file that genuinely has it.
        """
        primary: list[str] = []
        overlay: list[str] = []
        claimed: list[str] = []
        doc_route_ids: list[str] = []
        read_first: list[str] = []
        unrouted: list[str] = []
        matched_paths: dict[str, list[str]] = {}
        # Owners in the order the caller's arguments produced them, so the first
        # path named is the first owner to read. A rule demoted for an earlier
        # path takes its place at the argument that made it primary, not at the
        # one that merely mentioned it.
        owners: list[dict] = []
        owner_ids: set[str] = set()

        def add(seq: list[str], value: str) -> None:
            if value not in seq:
                seq.append(value)

        def add_domain_owner(rid: str) -> None:
            if rid in owner_ids:
                return
            owner_ids.add(rid)
            add(primary, rid)
            domain = self.domains.get(rid, {})
            owners.append({"id": rid, "name": domain.get("name", rid),
                           "read_first": domain.get("read_first", []),
                           "conditional": domain.get("conditional", [])})

        def add_route_owner(route: dict) -> None:
            if route["id"] in owner_ids:
                return
            owner_ids.add(route["id"])
            doc_route_ids.append(route["id"])
            owners.append({"id": route["id"], "name": route.get("name", route["id"]),
                           "read_first": self.route_docs(route),
                           "conditional": route.get("conditional", [])})

        for target in targets:
            if target in self.domains or target in self.rules:
                add(claimed, target)
                if self.role_of(target) == OVERLAY:
                    add(overlay, target)
                else:
                    add_domain_owner(target)
                continue

            claims = self.claims_for(target)
            if not claims["qa"] and claims["doc_route"] is None:
                unrouted.append(target)
                continue

            if claims["qa"]:
                matched_paths[target] = claims["qa"]
            for rid in claims["qa"]:
                add(claimed, rid)
            if claims["doc_route"] is not None:
                add_route_owner(claims["doc_route"])
            for rid in claims["primary"]:
                add_domain_owner(rid)
            for rid in claims["overlay"]:
                add(overlay, rid)

        # A domain that is primary for any one path is a primary owner of the
        # change. Being demoted elsewhere does not take that away.
        overlay = [r for r in overlay if r not in primary]

        # Group routing entries by the canonical document set they point at.
        #
        # A routing entry id is provenance — which table produced this owner — not
        # architecture. Two entries can honestly name the same canonical owner:
        # `Resources/*.lproj/Localizable.strings` reaches localization.md through a
        # document route and `AppLanguageService.swift` reaches it through a QA
        # domain, and a diff touching both is one documentation domain, not two.
        # Counting entries called that a cross-domain change.
        #
        # Identity is the *set* of read_first documents, not the ordered list: two
        # entries naming the same two documents in different orders are the same
        # owner, and letting declaration order split them would reintroduce the
        # same false escalation one level down. A superset is deliberately a
        # different owner — an entry requiring an extra document genuinely requires
        # more reading. An entry with no read_first cannot be grouped by document,
        # so it keys on its own id and can never collapse into an unrelated one.
        groups: list[dict] = []
        by_documents: dict[object, dict] = {}
        for owner in owners:
            key = frozenset(owner["read_first"]) or owner["id"]
            group = by_documents.get(key)
            if group is None:
                group = {"documents": [], "names": [], "entries": []}
                by_documents[key] = group
                groups.append(group)
            for doc in owner["read_first"]:
                add(group["documents"], doc)
            group["names"].append(owner["name"])
            group["entries"].append(owner["id"])

        conditional: list[dict] = []
        for group in groups:
            for doc in group["documents"]:
                add(read_first, doc)
        # Conditionals stay a union across *entries*, not groups. Grouping removes a
        # duplicated canonical document; it must not quietly drop the triggers the
        # other entry contributed — a string-table change still needs the website
        # and legal triggers that the language service does not carry.
        for owner in owners:
            for item in owner["conditional"]:
                if item["doc"] not in {c["doc"] for c in conditional}:
                    conditional.append(item)

        # An overlay's conditional owners are the route of last resort for the
        # paths it is the *only* claimant of. Offering them next to a real owner
        # is noise: PowerPane cannot change the menu-bar status item, so a trigger
        # it can never meet teaches the reader to skim triggers rather than check
        # them.
        if not owners:
            for rid in overlay:
                for item in self.domains.get(rid, {}).get("conditional", []):
                    if item["doc"] not in {c["doc"] for c in conditional}:
                        conditional.append(item)

        # Tests and QA IDs come from every rule that claims the path, whether it
        # documents it or not. Demotion is about documentation, never verification.
        tests: list[str] = []
        qa_ids: list[str] = []
        for rid in claimed:
            rule = self.rules.get(rid, {})
            for glob in rule.get("test_globs", []):
                for f in self.tracked:
                    if fnmatch.fnmatch(f, glob):
                        add(tests, f)
            for qid in rule.get("qa_ids", []):
                add(qa_ids, qid)

        # A conditional owner that is already required unconditionally is not a
        # conditional: listing it twice would invite re-reading it.
        conditional = [c for c in conditional if c["doc"] not in read_first]

        sources = [t for t in targets if t not in self.domains and t not in self.rules]
        return {
            "domains": claimed,
            "domain_names": [o["name"] for o in owners]
                            + [self.domains.get(r, {}).get("name", r) for r in overlay],
            "primary_domains": primary,
            "primary_owners": [o["id"] for o in owners],
            "primary_owner_names": [o["name"] for o in owners],
            # One entry per distinct canonical owner. `entries` keeps the provenance
            # that grouping would otherwise hide.
            "canonical_owners": [
                {"documents": g["documents"], "names": g["names"], "entries": g["entries"]}
                for g in groups
            ],
            "canonical_owner_names": [" / ".join(g["names"]) for g in groups],
            "document_routes": doc_route_ids,
            "overlay_domains": overlay,
            "overlay_domain_names": [self.domains.get(r, {}).get("name", r) for r in overlay],
            "read_first": read_first,
            "sources": sources,
            "tests": tests,
            "qa_ids": qa_ids,
            "conditional": conditional,
            "unrouted": unrouted,
            "matched": matched_paths,
            # Escalation counts distinct canonical documentation owners — not rule
            # matches, and not routing entries. A broad QA overlay, a file that
            # three rules verify, and two tables that name the same document are
            # none of them architecture domains, and must never read like one.
            "cross_domain": len(groups) > 1,
            "overlay_only": bool(overlay) and not owners,
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
    if route["canonical_owner_names"]:
        out.append("DOMAIN: " + ", ".join(route["canonical_owner_names"]))
    else:
        out.append("DOMAIN: (unresolved)")

    # Printed on its own line, never merged into DOMAIN: an overlay owns the
    # verification of these paths, not their documentation, and the difference
    # is the whole point of separating the two.
    if route["overlay_domain_names"]:
        out.append("QA OVERLAY: " + ", ".join(route["overlay_domain_names"]))

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
    if route["overlay_only"]:
        out.append("- NO PRIMARY DOMAIN: these paths are claimed only by a QA overlay, which")
        out.append("  owns their tests and QA IDs but not their canonical document. Use the")
        out.append("  triggers under CONDITIONAL; if none of them fits, fall back to")
        out.append(f"  {route['fallback_doc']} and add a primary route.")
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
    args = parser.parse_args()

    route = Router().resolve(args.targets)
    if args.as_json:
        print(json.dumps(route, indent=2, ensure_ascii=False, sort_keys=True))
    else:
        print(render(route))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
