import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def load_module():
    path = ROOT / "Scripts/check-qa-impact.py"
    spec = importlib.util.spec_from_file_location("qa_impact", path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


qa = load_module()


class QAImpactTests(unittest.TestCase):
    def setUp(self):
        self.scenarios = {
            "DISP-01": qa.Scenario("DISP-01", "Built-in display", "mixed"),
            "UI-05": qa.Scenario("UI-05", "Keyboard handoff", "mixed"),
            "PERM-03": qa.Scenario("PERM-03", "Calendar grant", "mixed"),
            "DATA-01": qa.Scenario("DATA-01", "Old settings", "automated"),
        }
        self.config = qa.Config(
            matrix_path=Path("unused"),
            release_evidence_directory=Path("unused"),
            tracked_source_globs=("Sources/Impuls/**/*.swift",),
            exemptions=(
                qa.Exemption(
                    ("Sources/Impuls/Services/VersionTelemetryService.swift",),
                    "Telemetry is deliberately outside Behavioral QA.",
                ),
            ),
            rules=(
                qa.Rule(
                    "display",
                    "Display behavior changed",
                    ("Sources/Impuls/Notch/*.swift",),
                    ("Tests/ImpulsTests/DisplayTopologyTests.swift",),
                    ("DISP-01", "UI-05"),
                ),
                qa.Rule(
                    "calendar",
                    "Calendar behavior changed",
                    ("Sources/Impuls/Services/CalendarStore.swift",),
                    ("Tests/ImpulsTests/CalendarStoreTests.swift",),
                    ("PERM-03",),
                ),
                qa.Rule(
                    "settings",
                    "Settings compatibility changed",
                    ("Sources/Impuls/Settings/SettingsStore.swift",),
                    ("Tests/ImpulsTests/SettingsStoreTests.swift",),
                    ("DATA-01",),
                ),
            ),
        )

    def test_repository_configuration_covers_current_matrix(self):
        config, scenarios = qa.load_config()
        self.assertGreaterEqual(len(config.rules), 10)
        self.assertGreaterEqual(len(scenarios), 50)

    def test_source_change_maps_to_behavioral_ids(self):
        impacts, errors, exemptions, rules = qa.evaluate_files(
            {"Sources/Impuls/Notch/NotchController.swift"},
            self.config,
            self.scenarios,
        )
        self.assertEqual(errors, [])
        self.assertEqual(exemptions, {})
        self.assertEqual(set(impacts), {"DISP-01", "UI-05"})
        self.assertEqual(rules, {"display"})
        self.assertIn(
            "Sources/Impuls/Notch/NotchController.swift",
            impacts["DISP-01"].source_files,
        )

    def test_test_change_maps_to_same_ids_without_source_error(self):
        impacts, errors, _exemptions, rules = qa.evaluate_files(
            {"Tests/ImpulsTests/CalendarStoreTests.swift"},
            self.config,
            self.scenarios,
        )
        self.assertEqual(errors, [])
        self.assertEqual(set(impacts), {"PERM-03"})
        self.assertEqual(rules, {"calendar"})
        self.assertIn(
            "Tests/ImpulsTests/CalendarStoreTests.swift",
            impacts["PERM-03"].test_files,
        )

    def test_unmapped_behavioral_source_fails_closed(self):
        impacts, errors, exemptions, _rules = qa.evaluate_files(
            {"Sources/Impuls/Services/NewBehavioralService.swift"},
            self.config,
            self.scenarios,
        )
        self.assertEqual(impacts, {})
        self.assertEqual(exemptions, {})
        self.assertTrue(any("unmapped behavioral source change" in error for error in errors))

    def test_narrow_exemption_is_visible(self):
        impacts, errors, exemptions, _rules = qa.evaluate_files(
            {"Sources/Impuls/Services/VersionTelemetryService.swift"},
            self.config,
            self.scenarios,
        )
        self.assertEqual(impacts, {})
        self.assertEqual(errors, [])
        self.assertIn("Sources/Impuls/Services/VersionTelemetryService.swift", exemptions)

    def test_release_candidate_requires_impacted_manual_ids_in_evidence(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            config = qa.Config(
                self.config.matrix_path,
                directory,
                self.config.tracked_source_globs,
                self.config.exemptions,
                self.config.rules,
            )
            (directory / "1.4.12.md").write_text(
                """<!-- qa-results:start -->
| ID | Result | Environment | Evidence | Notes |
| --- | --- | --- | --- | --- |
| DISP-01 | pass | MAC-01 | manual | ok |
<!-- qa-results:end -->
""",
                encoding="utf-8",
            )
            impacts = {
                "DISP-01": qa.Impact({"source.swift"}, set(), {"display"}),
                "UI-05": qa.Impact({"source.swift"}, set(), {"display"}),
                "DATA-01": qa.Impact({"settings.swift"}, set(), {"settings"}),
            }
            errors, results = qa.release_evidence_errors(
                "1.4.12", impacts, self.scenarios, config
            )
            self.assertTrue(any("UI-05" in error for error in errors))
            self.assertEqual(results.get("DISP-01"), "pass")

    def test_automated_impact_does_not_require_release_evidence_row(self):
        with tempfile.TemporaryDirectory() as temporary:
            config = qa.Config(
                self.config.matrix_path,
                Path(temporary),
                self.config.tracked_source_globs,
                self.config.exemptions,
                self.config.rules,
            )
            impacts = {
                "DATA-01": qa.Impact({"settings.swift"}, set(), {"settings"})
            }
            errors, results = qa.release_evidence_errors(
                "1.4.12", impacts, self.scenarios, config
            )
            self.assertEqual(errors, [])
            self.assertEqual(results, {})


if __name__ == "__main__":
    unittest.main()
