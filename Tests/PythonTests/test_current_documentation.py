import importlib.util
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Scripts" / "check-current-documentation.py"
SPEC = importlib.util.spec_from_file_location("current_documentation_check", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
CHECKER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECKER)


class CurrentDocumentationTests(unittest.TestCase):
    def test_current_repository_contract_is_consistent(self):
        self.assertEqual([], CHECKER.validate_data())

    def test_all_localization_surfaces_use_the_same_current_set(self):
        app = CHECKER.resource_locales()
        self.assertEqual(app, CHECKER.app_language_locales())
        self.assertEqual(app, CHECKER.bundle_locales())
        self.assertEqual(app, CHECKER.registry_locales())
        self.assertEqual(app, CHECKER.privacy_locales())

    def test_zh_hans_route_is_registry_owned_not_guessed_from_code(self):
        entry = next(item for item in CHECKER.locale_registry()["locales"] if item["code"] == "zh-Hans")
        self.assertEqual("zh-hans/", entry["path"])
        self.assertEqual("zh-hans/privacy/", entry["privacy_path"])

    def test_agent_manifest_exposes_localization_and_legal_routes(self):
        import json

        manifest = json.loads(CHECKER.read("PROJECT-MANIFEST.json"))
        self.assertEqual(
            "knowledge-base/04-development/localization.md",
            manifest["product"]["localization_doc"],
        )
        self.assertEqual(
            "knowledge-base/07-web/legal-privacy.md",
            manifest["web_and_collector"]["website_legal_doc"],
        )
        self.assertEqual(
            "Scripts/site-locales/registry.json",
            manifest["web_and_collector"]["website_locale_registry"],
        )

    def test_public_readmes_expose_current_locale_count_and_policy_route(self):
        count = len(CHECKER.resource_locales())
        en = CHECKER.read("README.md").lower()
        ru = CHECKER.read("README.ru.md").lower()
        self.assertTrue(
            f"{count} interface languages" in en
            or (count == 7 and "seven interface languages" in en)
        )
        self.assertIn(f"{count} языков интерфейса", ru)
        policy = "https://tumanovnv.github.io/impuls/privacy/"
        self.assertIn(policy, en)
        self.assertIn(policy, ru)


if __name__ == "__main__":
    unittest.main()
