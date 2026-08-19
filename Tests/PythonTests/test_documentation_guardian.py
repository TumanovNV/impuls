import importlib.util
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Scripts" / "check-documentation-guardian.py"
SPEC = importlib.util.spec_from_file_location("documentation_guardian", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
GUARDIAN = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GUARDIAN)


class DocumentationGuardianTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.rules = {rule["id"]: rule for rule in GUARDIAN.load_rules()}

    def evaluate(self, rule_id, files, lines):
        return GUARDIAN.evaluate(set(files), list(lines), [self.rules[rule_id]])

    def test_recursive_source_glob_matches_nested_swift_file(self):
        self.assertTrue(
            GUARDIAN.matches_path(
                "Sources/Impuls/Services/Example.swift",
                ["Sources/**/*.swift"],
            )
        )

    def test_guardian_v2_rule_families_are_present(self):
        self.assertGreaterEqual(len(self.rules), 11)
        self.assertTrue(
            {
                "privacy-device-identity",
                "telemetry-payload-privacy",
                "update-signing-integrity",
                "ownership-actor-boundary",
                "module-topology",
            }.issubset(self.rules)
        )

    def test_background_timer_requires_registry_review(self):
        path = "Sources/Impuls/Services/Example.swift"
        errors = self.evaluate(
            "background-concurrency",
            {path},
            [(path, "let timer = Timer(timeInterval: 1, repeats: true) { _ in")],
        )
        self.assertEqual(1, len(errors))
        self.assertIn("background-concurrency", errors[0])

    def test_background_timer_passes_when_registry_is_in_diff(self):
        path = "Sources/Impuls/Services/Example.swift"
        doc = "knowledge-base/12-reference/background-concurrency-registry.md"
        errors = self.evaluate(
            "background-concurrency",
            {path, doc},
            [(path, "let timer = Timer(timeInterval: 1, repeats: true) { _ in")],
        )
        self.assertEqual([], errors)

    def test_removed_contract_line_is_still_a_hit(self):
        path = "Sources/Impuls/Services/Example.swift"
        errors = self.evaluate(
            "background-concurrency",
            {path},
            [(path, "timer.tolerance = 0.25")],
        )
        self.assertEqual(1, len(errors))

    def test_resource_budget_change_requires_budget_registry(self):
        path = "Sources/Impuls/Services/Example.swift"
        errors = self.evaluate(
            "resource-budgets",
            {path},
            [(path, "static let maximumPayloadBytes = 128 * 1_024")],
        )
        self.assertEqual(1, len(errors))
        self.assertIn("resource-budgets", errors[0])

    def test_permission_rule_accepts_either_canonical_permission_doc(self):
        path = "Sources/Impuls/Services/Example.swift"
        tcc_doc = "knowledge-base/03-macos/permissions-and-tcc.md"
        errors = self.evaluate(
            "permissions",
            {path, tcc_doc},
            [(path, "requestAuthorization(options: [.alert])")],
        )
        self.assertEqual([], errors)

    def test_device_identity_change_requires_privacy_review(self):
        path = "Sources/Impuls/Services/AppleDeviceIdentity.swift"
        errors = self.evaluate(
            "privacy-device-identity",
            {path},
            [(path, "func identity(forRawIdentifier rawIdentifier: String, kind: AppleDeviceKind)")],
        )
        self.assertEqual(1, len(errors))
        self.assertIn("privacy-device-identity", errors[0])

    def test_device_identity_change_accepts_privacy_boundary_review(self):
        path = "Sources/Impuls/Services/AppleDeviceIdentity.swift"
        doc = "knowledge-base/06-security/privacy-boundaries.md"
        errors = self.evaluate(
            "privacy-device-identity",
            {path, doc},
            [(path, "query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly")],
        )
        self.assertEqual([], errors)

    def test_telemetry_payload_change_requires_collector_or_privacy_review(self):
        path = "Sources/Impuls/Services/VersionTelemetryService.swift"
        errors = self.evaluate(
            "telemetry-payload-privacy",
            {path},
            [(path, 'case installationID = "installation_id"')],
        )
        self.assertEqual(1, len(errors))
        self.assertIn("telemetry-payload-privacy", errors[0])

    def test_sparkle_integrity_change_requires_release_security_review(self):
        path = "Scripts/bundle.sh"
        errors = self.evaluate(
            "update-signing-integrity",
            {path},
            [(path, "set_plist_bool SUVerifyUpdateBeforeExtraction true")],
        )
        self.assertEqual(1, len(errors))
        self.assertIn("update-signing-integrity", errors[0])

    def test_actor_ownership_change_requires_ownership_review(self):
        path = "Sources/Impuls/Services/Example.swift"
        errors = self.evaluate(
            "ownership-actor-boundary",
            {path},
            [(path, "final class Example: @unchecked Sendable {")],
        )
        self.assertEqual(1, len(errors))
        self.assertIn("ownership-actor-boundary", errors[0])

    def test_module_topology_change_requires_project_manifest(self):
        path = "Sources/Impuls/Services/AppFeatureCatalog.swift"
        line = "feature(.power, detail: \"Battery status\"),"
        errors = self.evaluate("module-topology", {path}, [(path, line)])
        self.assertEqual(1, len(errors))

        errors = self.evaluate(
            "module-topology",
            {path, "PROJECT-MANIFEST.json"},
            [(path, line)],
        )
        self.assertEqual([], errors)

    def test_unrelated_swift_change_does_not_create_false_positive(self):
        path = "Sources/Impuls/Services/Example.swift"
        errors = GUARDIAN.evaluate(
            {path},
            [(path, 'let title = localized("Example")')],
            list(self.rules.values()),
        )
        self.assertEqual([], errors)


if __name__ == "__main__":
    unittest.main()
