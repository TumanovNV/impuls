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

STRINGS_EN = "Resources/en.lproj/Localizable.strings"
STRINGS_JA = "Resources/ja.lproj/Localizable.strings"
VERSION_FILE = "Scripts/version"
SETTINGS = "Sources/Impuls/Settings/SettingsWindow.swift"
TELEMETRY = "Sources/Impuls/Services/VersionTelemetryService.swift"
SUPPORT = "Sources/Impuls/Services/ProjectSupportPromptService.swift"

LOCALIZATION_DOC = "knowledge-base/04-development/localization.md"
RELEASE_DOC = "knowledge-base/05-release/release-process.md"
SETTINGS_DOC = "knowledge-base/01-architecture/settings-onboarding-feedback.md"


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

    def test_the_generic_router_never_routes_to_an_agents_private_rules(self):
        """`Scripts/agent-context.py` is read by Claude and by Codex.

        `.claude/rules/swift-ui.md` carries its own `paths:` frontmatter, so Claude
        already loads it for exactly these paths. Repeating it in the generic route
        duplicated that for one agent and sent every other agent into a config file
        that is not theirs.
        """
        for target in (UI, "Sources/Impuls/Notch/NotchController.swift", MUSIC, POWER):
            route = self.route(target)
            for doc in route["read_first"] + [c["doc"] for c in route["conditional"]]:
                self.assertFalse(
                    doc.startswith(".claude/"),
                    f"generic route for {target} names the Claude-private file {doc}")

    def test_no_declared_route_anywhere_names_an_agent_private_file(self):
        for domain in self.router.routing["domains"]:
            docs = list(domain.get("read_first", [])) + [
                c["doc"] for c in domain.get("conditional", [])]
            for doc in docs:
                self.assertFalse(doc.startswith((".claude/", ".codex/", ".cursor/")),
                                 f"{domain['id']} routes to {doc}")

    # -- paths a QA rule does not and should not own --------------------------

    def test_a_real_string_table_routes_to_the_localization_owner(self):
        """Where localization work actually starts.

        `AppLanguageService.swift` is the behavioural owner and has a QA rule; the
        string table an agent actually opens has neither, because
        `qa-impact-rules.json` tracks behavioural Swift source. Adding
        `Resources/*.lproj` there to satisfy the router would invent a behavioural
        owner that does not exist, so the documentation route carries it instead.
        """
        for path in (STRINGS_EN, STRINGS_JA):
            self.assertTrue((ROOT / path).is_file(), f"{path}: fixture must be a real file")
            route = self.route(path)
            self.assertEqual(route["unrouted"], [], path)
            self.assertEqual(route["read_first"],
                             ["knowledge-base/04-development/localization.md"], path)
            self.assertEqual(route["primary_owners"], ["app-localization-tables"], path)
            self.assertFalse(route["cross_domain"], path)
            self.assertNotIn("UNROUTED", agent_context.render(route))

    def test_the_version_file_routes_to_the_release_owner(self):
        self.assertTrue((ROOT / VERSION_FILE).is_file())
        route = self.route(VERSION_FILE)
        self.assertEqual(route["unrouted"], [])
        self.assertEqual(route["read_first"],
                         ["knowledge-base/05-release/release-process.md"])
        self.assertEqual(route["primary_owners"], ["version-source"])
        self.assertNotIn("UNROUTED", agent_context.render(route))

    def test_a_documentation_only_route_invents_no_tests_and_no_qa_ids(self):
        """The line this layer must not cross.

        It exists because these paths have no QA rule. If it started answering with
        tests or QA IDs it would be a second source/test database, which is the one
        thing the routing design refuses to have.
        """
        for path in (STRINGS_EN, STRINGS_JA, VERSION_FILE):
            route = self.route(path)
            self.assertEqual(route["qa_ids"], [], f"{path} must not invent QA IDs")
            self.assertEqual(route["tests"], [], f"{path} must not invent tests")
            self.assertEqual(route["domains"], [], f"{path} claims no QA rule")
            text = agent_context.render(route)
            self.assertNotIn("\nQA:", text)
            self.assertNotIn("\nTESTS:", text)

    def test_document_routes_use_the_manifest_instead_of_a_second_copy(self):
        router = self.router
        by_id = {r["id"]: r for r in router.doc_routes}
        self.assertEqual(router.deref("product.localization_doc"),
                         "knowledge-base/04-development/localization.md")
        self.assertEqual(router.route_globs(by_id["version-source"]),
                         [router.deref("product.version_source")])
        self.assertEqual(router.route_docs(by_id["app-localization-tables"]),
                         [router.deref("product.localization_doc")])
        self.assertEqual(router.route_docs(by_id["version-source"]),
                         [router.deref("release.canonical_docs.0")])

    # -- documentation ownership is per path, not per rule --------------------

    def test_one_window_hosting_every_setting_is_not_a_cross_domain_change(self):
        """Three QA rules claim `SettingsWindow.swift`, because one window hosts
        every setting. Two of them are primary domains elsewhere, so a generic
        Settings edit announced itself as a localization-plus-telemetry
        architecture change and demanded three canonical documents."""
        route = self.route(SETTINGS)

        self.assertEqual(route["primary_owners"], ["settings-window"])
        self.assertEqual(route["read_first"],
                         ["knowledge-base/01-architecture/settings-onboarding-feedback.md"])
        self.assertFalse(route["cross_domain"])

        self.assertNotIn("knowledge-base/04-development/localization.md", route["read_first"])
        self.assertNotIn("knowledge-base/07-web/version-statistics-collector.md",
                         route["read_first"])

        for rid in ("appearance-accessibility", "interface-language",
                    "version-statistics-diagnostics"):
            self.assertIn(rid, route["overlay_domains"], rid)
            self.assertIn(rid, route["domains"], rid)
        self.assertTrue(route["tests"], "every claiming rule still contributes its tests")
        self.assertTrue(route["qa_ids"], "every claiming rule still contributes its QA IDs")

        text = agent_context.render(route)
        self.assertNotIn("ESCALATED: CROSS-DOMAIN CHANGE", text)

    def test_demotion_is_per_path_and_never_leaks_to_the_owning_file(self):
        """`interface-language` is demoted for the Settings window. It must stay
        primary for the file it genuinely owns."""
        route = self.route(LANGUAGE)
        self.assertEqual(route["primary_owners"], ["interface-language"])
        self.assertEqual(route["read_first"], ["knowledge-base/04-development/localization.md"])
        self.assertEqual(route["overlay_domains"], [])

        route = self.route(TELEMETRY)
        self.assertEqual(route["primary_owners"], ["version-statistics-diagnostics"])
        self.assertEqual(route["read_first"],
                         ["knowledge-base/07-web/version-statistics-collector.md"])

    def test_a_rule_demoted_for_one_path_is_still_primary_for_another_in_the_same_diff(self):
        """The union again, now across the demotion boundary: changing the Settings
        window *and* the language service needs the localization owner, from the
        file that actually has it."""
        for targets in ([SETTINGS, LANGUAGE], [LANGUAGE, SETTINGS]):
            route = self.route(*targets)
            self.assertIn("interface-language", route["primary_owners"], str(targets))
            self.assertIn("settings-window", route["primary_owners"], str(targets))
            self.assertIn("knowledge-base/04-development/localization.md",
                          route["read_first"], str(targets))
            self.assertNotIn("interface-language", route["overlay_domains"], str(targets))
            self.assertTrue(route["cross_domain"], str(targets))

    def test_the_real_owners_of_a_demoted_rule_stay_reachable_as_triggers(self):
        docs = self.conditional_docs(self.route(SETTINGS))
        self.assertIn("knowledge-base/04-development/localization.md", docs)
        self.assertIn("knowledge-base/07-web/version-statistics-collector.md", docs)

    # -- a QA rule is not a documentation domain ------------------------------

    def test_a_module_pane_gets_its_module_owner_and_nobody_elses(self):
        """The 1.4.16 defect, kept as a fixture.

        `appearance-accessibility` claims `Sources/Impuls/UI/*.swift`, because every
        pane inherits the panel's appearance and accessibility QA. Treating that QA
        rule as a documentation domain gave PowerPane a second canonical owner —
        `menu-bar.md`, which owns the status item and has nothing to do with battery
        rows — and reported an ordinary pane edit as a cross-domain architecture
        change. The QA overlay is still applied; only its documentation claim is gone.
        """
        route = self.route(UI)

        self.assertEqual(route["primary_domains"], ["power-devices"])
        self.assertEqual(route["read_first"], ["knowledge-base/02-modules/power.md"])
        self.assertIn("appearance-accessibility", route["overlay_domains"])
        self.assertIn("appearance-accessibility", route["domains"])

        self.assertNotIn("knowledge-base/02-modules/menu-bar.md", route["read_first"])
        self.assertFalse(route["cross_domain"],
                         "a broad QA overlay is not a second architecture domain")

        self.assertTrue(any(q.startswith("PWR-") for q in route["qa_ids"]))
        self.assertTrue(any(q.startswith("UI-") for q in route["qa_ids"]),
                        "the overlay must still contribute its appearance QA IDs")
        self.assertIn("Tests/ImpulsTests/MenuBarStatusItemPresentationTests.swift",
                      route["tests"], "the overlay must still contribute its tests")

        text = agent_context.render(route)
        self.assertIn("DOMAIN: Power / Apple devices", text)
        self.assertIn("QA OVERLAY:", text)
        self.assertNotIn("ESCALATED: CROSS-DOMAIN CHANGE", text)
        self.assertNotIn("menu-bar.md", text)

    def test_the_same_holds_for_every_other_pane_the_overlay_claims(self):
        """One pane could be a coincidence; the rule is general."""
        for path, domain, owner in (
            ("Sources/Impuls/UI/TranslatePane.swift", "translation",
             "knowledge-base/02-modules/translate.md"),
            ("Sources/Impuls/UI/CalendarPane.swift", "calendar-permissions",
             "knowledge-base/02-modules/calendar.md"),
            ("Sources/Impuls/UI/ShelfPane.swift", "file-tools",
             "knowledge-base/02-modules/shelf.md"),
        ):
            route = self.route(path)
            self.assertEqual(route["primary_domains"], [domain], path)
            self.assertEqual(route["read_first"], [owner], path)
            self.assertNotIn("knowledge-base/02-modules/menu-bar.md", route["read_first"], path)
            self.assertFalse(route["cross_domain"], path)
            self.assertIn("appearance-accessibility", route["overlay_domains"], path)

    def test_two_real_domains_still_escalate(self):
        """The overlay change must not disable escalation that is genuinely earned."""
        route = self.route(UI, PERSIST)
        self.assertTrue(route["cross_domain"])
        self.assertEqual(set(route["primary_domains"]), {"power-devices", "local-data"})

    def test_an_overlay_still_reaches_its_real_owner_through_a_trigger(self):
        """A menu-bar change is claimed only by the overlay. It must still be told
        about `menu-bar.md` — as a trigger it obviously meets, not as a canonical
        owner forced on every pane — and must be told no primary domain exists."""
        route = self.route("Sources/Impuls/App/MenuBarStatusItemPresentation.swift")
        self.assertEqual(route["primary_domains"], [])
        self.assertTrue(route["overlay_only"])
        self.assertIn("knowledge-base/02-modules/menu-bar.md", self.conditional_docs(route))
        text = agent_context.render(route)
        self.assertIn("NO PRIMARY DOMAIN", text)
        self.assertIn("knowledge-base/02-modules/menu-bar.md", text)

    def test_an_overlay_declares_why_it_is_one(self):
        overlays = [d for d in self.router.routing["domains"]
                    if d.get("route_role") == "overlay"]
        self.assertTrue(overlays, "the fixture assumes at least one overlay exists")
        for domain in overlays:
            self.assertNotIn("read_first", domain, domain["id"])
            self.assertTrue(domain.get("overlay_reason"), domain["id"])

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

    # -- one canonical owner reached two ways ---------------------------------

    def assert_one_canonical_owner(self, targets, document, entries):
        """Two routing entries, one canonical document, therefore one domain."""
        route = self.route(*targets)
        self.assertEqual(route["read_first"], [document], str(targets))
        self.assertEqual(len(route["canonical_owners"]), 1, route["canonical_owners"])
        self.assertEqual(route["canonical_owners"][0]["documents"], [document])
        self.assertEqual(sorted(route["canonical_owners"][0]["entries"]), sorted(entries),
                         "provenance must survive grouping")
        self.assertFalse(route["cross_domain"], str(targets))
        text = agent_context.render(route)
        self.assertNotIn("ESCALATED: CROSS-DOMAIN CHANGE", text)
        self.assertEqual(text.count(document), 1, "the owner is named once, not twice")
        return route

    def assert_conditionals_are_the_union(self, targets, mutual=True):
        """Grouping removes a duplicated canonical document. It must not remove the
        triggers the other entry contributed.

        `mutual` says whether this fixture has each side contributing something the
        other lacks. Where it does, that is the sharpest form of the check. Where
        one side's triggers are a subset of the other's — the two Settings surfaces
        are like that — the union is still the right assertion, but it only proves
        anything if run in both argument orders, so that the entry which loses the
        grouping race is the one whose triggers must survive.
        """
        combined = self.conditional_docs(self.route(*targets))
        parts = [self.conditional_docs(self.route(t)) for t in targets]
        union = set().union(*parts)
        self.assertEqual(combined, union, "grouping must not drop an entry's triggers")
        if mutual:
            for part in parts:
                self.assertTrue(combined > part,
                                "this fixture claims each side contributes something "
                                "the other does not")
        else:
            self.assertEqual(self.conditional_docs(self.route(*reversed(targets))), union,
                             "the subset entry must not swallow the superset's triggers")
        return combined

    def test_a_string_table_and_the_language_service_are_one_domain(self):
        """The false escalation grouping exists to remove.

        `Localizable.strings` reaches localization.md through a document route and
        `AppLanguageService.swift` reaches it through a QA domain. Two routing
        entries, one canonical owner — counting entries called an ordinary
        localization change cross-domain and told the reader to expect two
        architectures.
        """
        route = self.assert_one_canonical_owner(
            [STRINGS_EN, LANGUAGE], LOCALIZATION_DOC,
            ["app-localization-tables", "interface-language"])
        self.assertTrue(route["qa_ids"], "the QA domain still contributes its IDs")
        self.assertTrue(route["tests"])
        self.assertEqual(self.route(STRINGS_EN)["qa_ids"], [],
                         "and the document route still invents none of its own")

        docs = self.assert_conditionals_are_the_union([STRINGS_EN, LANGUAGE])
        self.assertIn("knowledge-base/07-web/website.md", docs)
        self.assertIn("knowledge-base/07-web/legal-privacy.md", docs)
        self.assertIn("knowledge-base/01-architecture/storage-persistence.md", docs)

    def test_the_version_file_and_the_update_service_are_one_domain(self):
        self.assert_one_canonical_owner(
            [VERSION_FILE, RELEASE], RELEASE_DOC, ["version-source", "release-update"])
        docs = self.assert_conditionals_are_the_union([VERSION_FILE, RELEASE])
        self.assertIn("knowledge-base/13-qa/release-evidence/README.md", docs)

    def test_two_settings_surfaces_are_one_domain(self):
        """`settings-window` is a document route and `project-support-prompt` is a QA
        domain; both are owned by the settings/onboarding/feedback document."""
        self.assert_one_canonical_owner(
            [SETTINGS, SUPPORT], SETTINGS_DOC, ["settings-window", "project-support-prompt"])
        # These two overlap almost entirely: the support prompt's triggers are a
        # subset of the Settings window's, so the meaningful check is that the
        # superset's extra trigger survives whichever entry is grouped first.
        docs = self.assert_conditionals_are_the_union([SETTINGS, SUPPORT], mutual=False)
        self.assertIn("knowledge-base/07-web/version-statistics-collector.md", docs)
        self.assertIn("knowledge-base/07-web/version-statistics-collector.md",
                      self.conditional_docs(self.route(SUPPORT, SETTINGS)))

    def test_grouping_is_order_independent(self):
        for targets in ([STRINGS_EN, LANGUAGE], [LANGUAGE, STRINGS_EN],
                        [VERSION_FILE, RELEASE], [RELEASE, VERSION_FILE],
                        [SETTINGS, SUPPORT], [SUPPORT, SETTINGS]):
            route = self.route(*targets)
            self.assertFalse(route["cross_domain"], str(targets))
            self.assertEqual(len(route["read_first"]), 1, str(targets))

    def test_a_genuine_cross_domain_change_still_escalates(self):
        """Grouping must not become a way of never escalating."""
        route = self.route(MUSIC, PERSIST)
        self.assertEqual(route["read_first"],
                         ["knowledge-base/02-modules/music.md",
                          "knowledge-base/01-architecture/storage-persistence.md"])
        self.assertEqual(len(route["canonical_owners"]), 2)
        self.assertTrue(route["cross_domain"])
        self.assertIn("ESCALATED: CROSS-DOMAIN CHANGE", agent_context.render(route))

    def test_canonical_identity_is_a_set_of_documents_not_an_ordered_list(self):
        """Two owners naming the same documents in different orders are the same
        owner. Letting declaration order split them would put the false escalation
        straight back, one level down."""
        router = self.router
        a = {"id": "a", "name": "A", "read_first": ["x.md", "y.md"], "conditional": []}
        b = {"id": "b", "name": "B", "read_first": ["y.md", "x.md"], "conditional": []}
        self.assertEqual(frozenset(a["read_first"]), frozenset(b["read_first"]))
        # A superset is deliberately a different owner: it requires more reading.
        c = {"id": "c", "name": "C", "read_first": ["x.md"], "conditional": []}
        self.assertNotEqual(frozenset(a["read_first"]), frozenset(c["read_first"]))
        self.assertTrue(router.doc_routes, "router fixture is loaded")

    def test_every_primary_owner_declares_at_least_one_canonical_document(self):
        """Grouping keys on documents, so an owner without one would key on its id
        and could never merge. That is the safe fallback rather than the intent —
        this pins the intent."""
        routing = self.router.routing
        for domain in routing["domains"]:
            if domain.get("route_role") == "overlay":
                self.assertNotIn("read_first", domain, domain["id"])
                continue
            self.assertTrue(domain.get("read_first"), domain["id"])
        for route in self.router.doc_routes:
            self.assertTrue(self.router.route_docs(route), route["id"])

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

    def cli_json(self, *targets):
        return subprocess.run(
            ["python3", "Scripts/agent-context.py", *targets, "--json"],
            cwd=ROOT, capture_output=True, text=True, check=True).stdout

    def test_the_same_invocation_is_byte_stable(self):
        """Two runs of the same command must produce the same bytes, so a route
        can be diffed and cached. Nothing here is about argument order."""
        self.assertEqual(self.cli_json(MUSIC, PERSIST), self.cli_json(MUSIC, PERSIST))

    def test_argument_order_changes_reading_order_but_not_the_route(self):
        """The intended semantics, stated rather than assumed.

        Input order is preserved on purpose: the first path an agent names is the
        first owner it is told to read, and a router that reshuffled that would be
        harder to act on. So reversed arguments are *not* required to be
        byte-identical — an earlier version of this test asserted they were, via
        `list.sort()`, which returns None and therefore only ever compared
        `None == None` and could never fail.

        What must hold is that reversing the arguments changes no route content:
        same domains, same owners, same tests, same QA IDs, same conditionals,
        same escalation.
        """
        forward = json.loads(self.cli_json(MUSIC, PERSIST))
        reverse = json.loads(self.cli_json(PERSIST, MUSIC))

        self.assertNotEqual(forward["read_first"], reverse["read_first"],
                            "the fixture only proves anything if the order really differs")

        for key in ("domains", "primary_domains", "overlay_domains",
                    "read_first", "tests", "qa_ids"):
            self.assertEqual(set(forward[key]), set(reverse[key]), f"{key} differs by input order")
            self.assertEqual(len(forward[key]), len(set(forward[key])), f"{key} has duplicates")

        self.assertEqual({(c["doc"], c["trigger"]) for c in forward["conditional"]},
                         {(c["doc"], c["trigger"]) for c in reverse["conditional"]})
        self.assertEqual(forward["cross_domain"], reverse["cross_domain"])
        self.assertEqual(forward["unrouted"], reverse["unrouted"])

    def test_the_order_that_is_preserved_is_the_order_that_was_asked_for(self):
        forward = json.loads(self.cli_json(MUSIC, PERSIST))
        reverse = json.loads(self.cli_json(PERSIST, MUSIC))
        self.assertEqual(forward["primary_domains"], ["music-and-web", "local-data"])
        self.assertEqual(reverse["primary_domains"], ["local-data", "music-and-web"])
        self.assertEqual(forward["read_first"], list(reversed(reverse["read_first"])))

    def test_the_router_has_no_historical_mode(self):
        """`--base <ref>` claimed to resolve deleted and renamed paths and did not.

        It swapped only the tracked-file list; the routing tables were still read
        from the working tree, so a file renamed on the branch was looked up in the
        branch's rules under its old name and could answer UNROUTED — the opposite
        of what the flag advertised. A wrong answer delivered confidently is worse
        than a missing feature, so the flag is gone rather than half-fixed.
        """
        result = subprocess.run(
            ["python3", "Scripts/agent-context.py", MUSIC, "--base", "main"],
            cwd=ROOT, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unrecognized arguments", result.stderr)

        source = (ROOT / "Scripts" / "agent-context.py").read_text(encoding="utf-8")
        self.assertNotIn("ls-tree", source, "no historical file listing remains")
        self.assertNotIn("add_argument(\"--base\"", source)

        with self.assertRaises(TypeError):
            agent_context.Router(base="main")

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

    # -- route completeness, both directions ---------------------------------

    def simulated_manifest(self, mutate):
        """Run the schema guard against a mutated copy of the real manifest."""
        errors = []
        original = check_agent_context.read_json

        def patched(rel):
            data = original(rel)
            if rel == "PROJECT-MANIFEST.json":
                data = json.loads(json.dumps(data))
                mutate(data)
            return data

        check_agent_context.read_json = patched
        try:
            check_agent_context.check_manifest_schema(errors)
        finally:
            check_agent_context.read_json = original
        return errors

    def test_a_qa_rule_without_a_route_fails_and_names_the_rule(self):
        """The hole the first version of this guard left open.

        It checked route -> QA rule and stopped there, so a new rule in
        `Scripts/qa-impact-rules.json` could ship with tests, QA IDs and no
        documentation route at all: the router would answer UNROUTED for a path CI
        considered fully owned, with every check green. Deleting a route must fail,
        and the failure must say which rule id lost it — an error that only says
        "something is missing" costs the next person the search.
        """
        removed = {}

        def drop_power(data):
            gone = [d for d in data["agent_routing"]["domains"] if d["id"] == "power-devices"]
            self.assertEqual(len(gone), 1, "fixture expects exactly one power-devices route")
            removed["id"] = gone[0]["id"]
            data["agent_routing"]["domains"] = [
                d for d in data["agent_routing"]["domains"] if d["id"] != "power-devices"]

        errors = self.simulated_manifest(drop_power)
        self.assertTrue(errors, "removing a route must not leave the guard green")
        named = [e for e in errors if "power-devices" in e]
        self.assertTrue(named, f"the failure must name the missing rule id: {errors}")
        self.assertTrue(any("no agent_routing domain" in e for e in named))

    def test_the_completeness_check_is_a_set_equality_in_both_directions(self):
        qa_ids = {r["id"] for r in
                  check_agent_context.read_json("Scripts/qa-impact-rules.json")["rules"]}
        routed = {d["id"] for d in check_agent_context.read_json(
            "PROJECT-MANIFEST.json")["agent_routing"]["domains"]}
        self.assertEqual(routed, qa_ids,
                         "every QA rule is routable and no route invents a rule; if that "
                         "ever stops being true, add an explicit exemption with a reason "
                         "rather than relaxing this")

        errors = []
        check_agent_context.check_route_completeness(
            errors, {"domains": [{"id": "a"}]}, {"a", "b"})
        self.assertTrue(any("'b'" in e or "b" in e for e in errors))

        errors = []
        check_agent_context.check_route_completeness(
            errors, {"domains": [{"id": "a"}, {"id": "z"}]}, {"a"})
        self.assertTrue(any("no matching QA rule id" in e for e in errors))

        errors = []
        check_agent_context.check_route_completeness(errors, {"domains": [{"id": "a"}]}, {"a"})
        self.assertEqual(errors, [])

    def test_an_overlay_that_grows_a_read_first_is_rejected(self):
        def promote(data):
            for domain in data["agent_routing"]["domains"]:
                if domain.get("route_role") == "overlay":
                    domain["read_first"] = ["knowledge-base/02-modules/menu-bar.md"]

        errors = self.simulated_manifest(promote)
        self.assertTrue(any("is an overlay but declares read_first" in e for e in errors))

    def test_a_domain_without_a_route_role_is_rejected(self):
        def strip(data):
            data["agent_routing"]["domains"][0].pop("route_role", None)

        errors = self.simulated_manifest(strip)
        self.assertTrue(any("route_role must be" in e for e in errors))

    def test_a_route_to_an_agent_private_rule_file_is_rejected(self):
        def add_claude_route(data):
            data["agent_routing"]["domains"][0].setdefault("conditional", []).append(
                {"doc": ".claude/rules/swift-ui.md", "trigger": "panel UI changed"})

        errors = self.simulated_manifest(add_claude_route)
        self.assertTrue(any("agent-specific rule file" in e for e in errors))

    # -- document routes stay documentation-only ------------------------------

    def test_a_document_route_carrying_test_globs_is_rejected(self):
        """The exact way this layer would turn into a second source/test database."""
        def add_tests(data):
            data["agent_routing"]["document_routes"][0]["test_globs"] = [
                "Tests/ImpulsTests/*.swift"]

        errors = self.simulated_manifest(add_tests)
        self.assertTrue(any("unknown key(s)" in e and "test_globs" in e for e in errors))

    def test_a_document_route_carrying_qa_ids_is_rejected(self):
        def add_ids(data):
            data["agent_routing"]["document_routes"][0]["qa_ids"] = ["UI-01"]

        errors = self.simulated_manifest(add_ids)
        self.assertTrue(any("unknown key(s)" in e and "qa_ids" in e for e in errors))

    def test_a_manifest_reference_that_stops_resolving_is_rejected(self):
        def break_ref(data):
            data["agent_routing"]["document_routes"][0]["read_first_ref"] = "product.no_such_key"

        errors = self.simulated_manifest(break_ref)
        self.assertTrue(any("does not resolve" in e for e in errors))

    def test_two_document_routes_claiming_one_path_are_rejected(self):
        def duplicate(data):
            routes = data["agent_routing"]["document_routes"]
            clone = json.loads(json.dumps(routes[0]))
            clone["id"] = "app-localization-tables-copy"
            routes.append(clone)

        errors = self.simulated_manifest(duplicate)
        self.assertTrue(any("more than one document_route" in e for e in errors))

    def test_a_document_route_that_collides_with_a_qa_rule_id_is_rejected(self):
        def collide(data):
            data["agent_routing"]["document_routes"][0]["id"] = "interface-language"

        errors = self.simulated_manifest(collide)
        self.assertTrue(any("collides with a QA rule id" in e for e in errors))

    def test_a_document_route_matching_no_tracked_file_is_rejected(self):
        def orphan(data):
            data["agent_routing"]["document_routes"][0]["globs"] = ["Resources/nope/*.strings"]
            data["agent_routing"]["document_routes"][0].pop("globs_ref", None)

        errors = self.simulated_manifest(orphan)
        self.assertTrue(any("dead routing" in e for e in errors))

    # -- the manifest describes its own validation ----------------------------

    def test_the_manifest_lists_the_agent_context_subsystem(self):
        validation = check_agent_context.read_json("PROJECT-MANIFEST.json")["validation"]
        for path in ("Scripts/agent-context.py", "Scripts/check-agent-context.py",
                     "Tests/PythonTests/test_agent_context.py"):
            self.assertIn(path, validation["repository_paths"])
            self.assertTrue((ROOT / path).is_file(), path)
        self.assertIn("python3 Scripts/check-agent-context.py", validation["commands"])

    # -- one bootstrap workflow ----------------------------------------------

    def test_the_repository_states_one_bootstrap_workflow(self):
        errors = []
        check_agent_context.check_single_workflow(errors)
        self.assertEqual(errors, [])

    def test_a_restored_preload_chain_is_rejected(self):
        """Non-vacuous by construction: the fixture is the exact sentence each of
        these files carried before this change."""
        cases = {
            "knowledge-base/10-ai/AI-INDEX.md":
                ("## Когда читать этот файл",
                 "Перед изменением проекта: `AGENTS.md` \u2192 root `PROJECT-MANIFEST.json` "
                 "\u2192 `AI-INDEX.md`.\n\n## Когда читать этот файл"),
            "knowledge-base/10-ai/repository-map.md":
                ("Cold-start route: `AGENTS.md` \u2192 `python3 Scripts/agent-context.py",
                 "Cold-start route: `AGENTS.md` \u2192 `PROJECT-MANIFEST.json` \u2192 "
                 "`AI-INDEX.md` \u2192 `python3 Scripts/agent-context.py"),
            "README.ru.md":
                ("  \u2192 python3 Scripts/agent-context.py <changed-path>",
                 "  \u2192 PROJECT-MANIFEST.json\n  \u2192 knowledge-base/10-ai/AI-INDEX.md"),
        }
        for rel, (old, new) in cases.items():
            path = ROOT / rel
            backup = path.read_text(encoding="utf-8")
            self.assertIn(old, backup, f"{rel}: the fixture no longer matches the file")
            errors = []
            try:
                path.write_text(backup.replace(old, new, 1), encoding="utf-8")
                check_agent_context.check_single_workflow(errors)
            finally:
                path.write_text(backup, encoding="utf-8")
            self.assertTrue(any(rel in e and "still chains" in e for e in errors),
                            f"{rel}: a restored preload chain was not caught")

    def test_an_entrypoint_that_stops_naming_the_router_is_rejected(self):
        path = ROOT / "knowledge-base/12-reference/README.md"
        backup = path.read_text(encoding="utf-8")
        errors = []
        try:
            path.write_text(backup.replace("Scripts/agent-context.py", "the manifest"),
                            encoding="utf-8")
            check_agent_context.check_single_workflow(errors)
        finally:
            path.write_text(backup, encoding="utf-8")
        self.assertTrue(any("never names" in e for e in errors))

    def test_every_declared_domain_resolves_and_round_trips(self):
        errors = []
        check_agent_context.check_router_resolves(errors)
        self.assertEqual(errors, [])


if __name__ == "__main__":
    unittest.main()
