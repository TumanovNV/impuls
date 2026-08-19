import copy
import importlib.util
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Scripts" / "check-dependency-policy.py"
SPEC = importlib.util.spec_from_file_location("dependency_policy_check", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
CHECKER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECKER)


class DependencyPolicyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.policy = CHECKER.load_policy()
        cls.resolved = CHECKER.load_resolved()
        cls.direct = CHECKER.direct_dependencies()

    def test_current_dependency_policy_is_valid(self):
        self.assertEqual(
            [],
            CHECKER.validate_data(
                copy.deepcopy(self.policy),
                copy.deepcopy(self.resolved),
                copy.deepcopy(self.direct),
            ),
        )

    def test_resolved_version_drift_is_rejected(self):
        resolved = copy.deepcopy(self.resolved)
        resolved["pins"][0]["state"]["version"] = "9.9.9"
        errors = CHECKER.validate_data(
            copy.deepcopy(self.policy), resolved, copy.deepcopy(self.direct)
        )
        self.assertTrue(any("version mismatch" in error for error in errors))

    def test_resolved_revision_drift_is_rejected(self):
        resolved = copy.deepcopy(self.resolved)
        resolved["pins"][0]["state"]["revision"] = "0" * 40
        errors = CHECKER.validate_data(
            copy.deepcopy(self.policy), resolved, copy.deepcopy(self.direct)
        )
        self.assertTrue(any("revision mismatch" in error for error in errors))

    def test_unapproved_pin_is_rejected(self):
        resolved = copy.deepcopy(self.resolved)
        resolved["pins"].append(
            {
                "identity": "unexpected",
                "kind": "remoteSourceControl",
                "location": "https://example.invalid/unexpected",
                "state": {"revision": "1" * 40, "version": "1.0.0"},
            }
        )
        errors = CHECKER.validate_data(
            copy.deepcopy(self.policy), resolved, copy.deepcopy(self.direct)
        )
        self.assertTrue(any("explicit allowlist" in error for error in errors))

    def test_non_exact_direct_requirement_is_rejected(self):
        policy = copy.deepcopy(self.policy)
        policy["dependencies"][0]["requirement"] = "from"
        errors = CHECKER.validate_data(
            policy, copy.deepcopy(self.resolved), copy.deepcopy(self.direct)
        )
        self.assertTrue(any("exact requirement" in error for error in errors))


if __name__ == "__main__":
    unittest.main()
