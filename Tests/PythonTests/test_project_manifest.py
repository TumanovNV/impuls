import copy
import importlib.util
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Scripts" / "check-project-manifest.py"
SPEC = importlib.util.spec_from_file_location("project_manifest_check", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
CHECKER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECKER)


class ProjectManifestTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.manifest = CHECKER.load_manifest()

    def test_current_manifest_is_valid(self):
        self.assertEqual([], CHECKER.validate_data(copy.deepcopy(self.manifest)))

    def test_shipped_module_catalog_matches_manifest(self):
        catalog = CHECKER.feature_catalog_ids(
            self.manifest["product"]["feature_catalog"]
        )
        manifest_ids = [module["id"] for module in self.manifest["modules"]]
        self.assertEqual(set(catalog), set(manifest_ids))
        self.assertEqual(9, len(manifest_ids))

    def test_missing_module_is_detected(self):
        data = copy.deepcopy(self.manifest)
        data["modules"] = data["modules"][:-1]
        errors = CHECKER.validate_data(data)
        self.assertTrue(any("module ids drifted" in error for error in errors))

    def test_fourth_network_owner_is_rejected(self):
        data = copy.deepcopy(self.manifest)
        data["network_owners"].append(
            {
                "id": "unexpected",
                "source": "Sources/Impuls/Services/CalendarStore.swift",
                "canonical_doc": "knowledge-base/01-architecture/networking.md"
            }
        )
        errors = CHECKER.validate_data(data)
        self.assertTrue(any("three-owner contract" in error for error in errors))

    def test_raw_public_ipv4_is_rejected(self):
        data = copy.deepcopy(self.manifest)
        data["operations_boundary"]["rule"] += " 10.20.30.40"
        errors = CHECKER.validate_data(data)
        self.assertTrue(any("raw IPv4" in error for error in errors))


if __name__ == "__main__":
    unittest.main()
