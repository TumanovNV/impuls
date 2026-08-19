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
