import copy
import importlib.util
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Scripts" / "generate-architecture-ledger.py"
SPEC = importlib.util.spec_from_file_location("architecture_ledger", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
LEDGER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(LEDGER)


class ArchitectureLedgerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.data = LEDGER.load_data()

    def test_current_milestones_are_valid(self):
        self.assertEqual([], LEDGER.validate_data(copy.deepcopy(self.data)))

    def test_entries_are_sorted(self):
        versions = [LEDGER.version_tuple(entry["version"]) for entry in self.data["entries"]]
        self.assertEqual(sorted(versions), versions)

    def test_duplicate_id_is_rejected(self):
        data = copy.deepcopy(self.data)
        data["entries"][1]["id"] = data["entries"][0]["id"]
        errors = LEDGER.validate_data(data)
        self.assertTrue(any("duplicate milestone id" in error for error in errors))

    def test_release_note_must_match_version(self):
        data = copy.deepcopy(self.data)
        data["entries"][0]["release_note"] = "docs/releases/1.3.0.md"
        errors = LEDGER.validate_data(data)
        self.assertTrue(any("release_note must be" in error for error in errors))

    def test_generated_output_is_deterministic(self):
        self.assertEqual(LEDGER.render(self.data), LEDGER.render(copy.deepcopy(self.data)))


if __name__ == "__main__":
    unittest.main()
