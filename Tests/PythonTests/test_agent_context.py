"""The documentation router, and the guard that keeps the bootstrap small.

The regression these exist for is specific: a route that quietly returns too
little is worse than no route at all, because an agent will trust it. The
multi-path cases below are the sharpest of those — an earlier design proposed
intersecting conditional owners across changed paths, which would have hidden
the persistence owner from a diff that also touched networking.
"""

import importlib.util
import json
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def load(name: str):
    spec = importlib.util.spec_from_file_location(
        name.replace("-", "_"), ROOT / "Scripts" / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


agent_context = load("agent-context")
check_agent_context = load("check-agent-context")

MUSIC = "Sources/Impuls/Services/WebMusicPlayer.swift"
POWER = "Sources/Impuls/Services/AppleAccessoryBatteryProvider.swift"
PERSIST = "Sources/Impuls/Services/ClipboardHistoryPersistence.swift"
LANGUAGE = "Sources/Impuls/Services/AppLanguageService.swift"
RELEASE = "Sources/Impuls/Services/UpdateService.swift"
UI = "Sources/Impuls/UI/PowerPane.swift"
UNKNOWN = "Sources/Impuls/Services/DeviceClock.swift"


class RouterTests(unittest.TestCase):
    def setUp(self):
        self.router = agent_context.Router()

    def route(self, *targets):
        return self.router.resolve(list(targets))

    def conditional_docs(self, route):
        return {c["doc"] for c in route["conditional"]}

    # -- one path, one domain ------------------------------------------------

    def test_music_path_routes_to_the_music_owner(self):
        route = self.route(MUSIC)
        self.assertIn("music-and-web", route["domains"])
        self.assertIn("knowledge-base/02-modules/music.md", route["read_first"])
        self.assertTrue(route["tests"], "a domain with tests must return them")
        self.assertTrue(any(q.startswith("MUS-") for q in route["qa_ids"]))
        self.assertIn("knowledge-base/01-architecture/networking.md",
                      self.conditional_docs(route))
        self.assertFalse(route["cross_domain"])

    def test_power_path_routes_to_the_power_owner(self):
        route = self.route(POWER)
        self.assertIn("power-devices", route["domains"])
        self.assertIn("knowledge-base/02-modules/power.md", route["read_first"])
        self.assertTrue(any(q.startswith("PWR-") for q in route["qa_ids"]))

    def test_persistence_path_routes_to_the_storage_owner(self):
        route = self.route(PERSIST)
        self.assertIn("local-data", route["domains"])
        self.assertIn("knowledge-base/01-architecture/storage-persistence.md",
                      route["read_first"])
        self.assertIn("knowledge-base/12-reference/schema-migration-registry.md",
                      self.conditional_docs(route))

    def test_localization_domain_resolves_by_name(self):
        route = self.route("interface-language")
        self.assertIn("interface-language", route["domains"])
        self.assertIn("knowledge-base/04-development/localization.md", route["read_first"])

    def test_localization_path_resolves(self):
        route = self.route(LANGUAGE)
        self.assertIn("interface-language", route["domains"])

    def test_release_path_routes_to_the_release_owner(self):
        route = self.route(RELEASE)
        self.assertIn("release-update", route["domains"])
        self.assertIn("knowledge-base/05-release/release-process.md", route["read_first"])

    def test_swift_ui_path_resolves_and_offers_the_scoped_rule(self):
        route = self.route(UI)
        self.assertTrue(route["domains"], "a UI path must resolve to at least one domain")
        self.assertIn("appearance-accessibility", route["domains"])
        self.assertIn(".claude/rules/swift-ui.md", self.conditional_docs(route))

    # -- unknown -------------------------------------------------------------

    def test_unknown_path_is_reported_rather_than_silently_empty(self):
        route = self.route(UNKNOWN)
        self.assertEqual(route["unrouted"], [UNKNOWN])
        self.assertEqual(route["domains"], [])
        self.assertTrue(route["fallback_doc"])
        text = agent_context.render(route)
        self.assertIn("UNROUTED", text)
        self.assertIn(route["fallback_doc"], text)

    def test_unknown_path_does_not_pull_in_every_domain(self):
        route = self.route(UNKNOWN)
        self.assertEqual(route["read_first"], [],
                         "an unresolved path must not open the whole knowledge base")

    # -- several paths: UNION, never intersection ----------------------------

    def test_two_paths_in_one_domain_stay_one_domain(self):
        route = self.route(MUSIC, "Sources/Impuls/Services/MediaController.swift")
        self.assertEqual(route["domains"], ["music-and-web"])
        self.assertFalse(route["cross_domain"])

    def test_music_plus_persistence_returns_both_owners(self):
        """The regression the intersection design would have caused."""
        route = self.route(MUSIC, PERSIST)
        self.assertIn("music-and-web", route["domains"])
        self.assertIn("local-data", route["domains"])
        self.assertIn("knowledge-base/02-modules/music.md", route["read_first"])
        self.assertIn("knowledge-base/01-architecture/storage-persistence.md",
                      route["read_first"])

    def test_conditional_owners_are_a_union_across_paths(self):
        docs = self.conditional_docs(self.route(MUSIC, PERSIST))
        self.assertIn("knowledge-base/01-architecture/networking.md", docs)
        self.assertIn("knowledge-base/12-reference/schema-migration-registry.md", docs)

        music_only = self.conditional_docs(self.route(MUSIC))
        persist_only = self.conditional_docs(self.route(PERSIST))
        self.assertEqual(docs, music_only | persist_only, "must be the union, not the intersection")
        self.assertTrue(music_only & persist_only, "the fixture is only meaningful if they overlap")
        self.assertNotEqual(docs, music_only & persist_only)

    def test_cross_domain_escalates_without_discarding_the_budget(self):
        route = self.route(MUSIC, PERSIST, POWER)
        self.assertTrue(route["cross_domain"])
        text = agent_context.render(route)
        self.assertIn("ESCALATED: CROSS-DOMAIN CHANGE", text)
        self.assertIn("not a reason to read the whole", text)
        self.assertIn("DO NOT LOAD BY DEFAULT", text)

    def test_a_conditional_owner_that_is_already_required_is_not_listed_twice(self):
        route = self.route(LANGUAGE)
        self.assertNotIn("knowledge-base/04-development/localization.md",
                         self.conditional_docs(route))
        self.assertIn("knowledge-base/04-development/localization.md", route["read_first"])

    # -- output --------------------------------------------------------------

    def test_json_output_is_deterministic(self):
        first = subprocess.run(
            ["python3", "Scripts/agent-context.py", MUSIC, PERSIST, "--json"],
            cwd=ROOT, capture_output=True, text=True, check=True).stdout
        second = subprocess.run(
            ["python3", "Scripts/agent-context.py", PERSIST, MUSIC, "--json"],
            cwd=ROOT, capture_output=True, text=True, check=True).stdout
        self.assertEqual(json.loads(first)["read_first"].sort(),
                         json.loads(second)["read_first"].sort())
        self.assertEqual(first, subprocess.run(
            ["python3", "Scripts/agent-context.py", MUSIC, PERSIST, "--json"],
            cwd=ROOT, capture_output=True, text=True, check=True).stdout)

    def test_human_output_never_omits_the_escape_hatch(self):
        for targets in ([MUSIC], [UNKNOWN], [MUSIC, PERSIST]):
            self.assertIn("never outranks correctness",
                          agent_context.render(self.route(*targets)))

    def test_the_router_makes_no_network_call(self):
        source = (ROOT / "Scripts" / "agent-context.py").read_text(encoding="utf-8")
        for banned in ("urllib", "requests", "http.client", "socket"):
            self.assertNotIn(banned, source)


class GuardTests(unittest.TestCase):
    def test_repository_passes_its_own_agent_context_guard(self):
        self.assertEqual(check_agent_context.main(), 0)

    def test_bootstrap_is_within_budget(self):
        total = sum(len((ROOT / n).read_bytes())
                    for n in check_agent_context.BOOTSTRAP_FILES)
        self.assertLessEqual(total, check_agent_context.BOOTSTRAP_BUDGET_BYTES)

    def test_budget_leaves_headroom_but_not_a_blank_cheque(self):
        total = sum(len((ROOT / n).read_bytes())
                    for n in check_agent_context.BOOTSTRAP_FILES)
        self.assertLess(check_agent_context.BOOTSTRAP_BUDGET_BYTES, total * 1.35,
                        "the ceiling should stop silent regrowth, not permit a rewrite")

    def test_an_unknown_manifest_key_is_rejected(self):
        errors = []
        original = check_agent_context.read_json

        def patched(rel):
            data = original(rel)
            if rel == "PROJECT-MANIFEST.json":
                data = dict(data)
                data["clipboard_retention_seconds"] = 604800
            return data

        check_agent_context.read_json = patched
        try:
            check_agent_context.check_manifest_schema(errors)
        finally:
            check_agent_context.read_json = original
        self.assertTrue(any("non-routing top-level key" in e for e in errors))

    def test_a_missing_canonical_doc_is_rejected(self):
        errors = []
        original = check_agent_context.read_json

        def patched(rel):
            data = original(rel)
            if rel == "PROJECT-MANIFEST.json":
                data = json.loads(json.dumps(data))
                data["agent_routing"]["domains"][0]["read_first"] = [
                    "knowledge-base/02-modules/does-not-exist.md"]
            return data

        check_agent_context.read_json = patched
        try:
            check_agent_context.check_manifest_schema(errors)
        finally:
            check_agent_context.read_json = original
        self.assertTrue(any("read_first missing" in e for e in errors))

    def test_a_domain_without_a_qa_impact_rule_is_rejected(self):
        errors = []
        original = check_agent_context.read_json

        def patched(rel):
            data = original(rel)
            if rel == "PROJECT-MANIFEST.json":
                data = json.loads(json.dumps(data))
                data["agent_routing"]["domains"][0]["id"] = "no-such-rule"
            return data

        check_agent_context.read_json = patched
        try:
            check_agent_context.check_manifest_schema(errors)
        finally:
            check_agent_context.read_json = original
        self.assertTrue(any("does not match a rule id" in e for e in errors))

    def test_every_declared_domain_resolves_and_round_trips(self):
        errors = []
        check_agent_context.check_router_resolves(errors)
        self.assertEqual(errors, [])


if __name__ == "__main__":
    unittest.main()
