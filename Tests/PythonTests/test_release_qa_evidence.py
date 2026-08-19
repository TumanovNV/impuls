import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def load_module():
    path = ROOT / "Scripts/check-release-qa-evidence.py"
    spec = importlib.util.spec_from_file_location("release_qa_evidence", path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


qa = load_module()


class ReleaseQAEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.policy = qa.Policy(
            enforce_from_version=(1, 4, 12),
            matrix_path=Path("unused"),
            evidence_directory=Path("unused"),
            manual_modes=frozenset({"mixed", "manual-macos", "manual-hardware", "manual-service"}),
            result_values=frozenset(
                {"pass", "fail", "blocked", "not-run", "not-applicable", "not-recorded"}
            ),
            release_decisions=frozenset(
                {"retrospective", "certified", "ship-with-known-gaps", "blocked"}
            ),
            environment_kinds=frozenset(
                {"real-mac", "real-mac-hardware", "service", "historical-unknown"}
            ),
        )
        self.scenarios = qa.parse_matrix(
            """
| ID | Scenario | Mode | Expected contract |
| --- | --- | --- | --- |
| PERM-01 | Fresh launch | manual-macos | no unsolicited prompt |
| PWR-02 | MagSafe | manual-hardware | truthful power data |
| REL-04 | Auto update checks | mixed | user-controlled behavior |
| MUS-05 | Web player | manual-service | official site only |
| DATA-01 | Old settings | automated | compatible |
""",
            self.policy.manual_modes,
        )

    def document(self, *, version="1.4.12", decision="certified", rows=None, kind="real-mac-hardware", known_gaps="- none"):
        rows = rows or {
            "PERM-01": ("pass", "MAC-01", "manual test", "Matched contract."),
            "PWR-02": ("pass", "MAC-01", "manual test", "Matched contract."),
            "REL-04": ("pass", "MAC-01", "manual test", "Matched contract."),
            "MUS-05": ("pass", "MAC-01", "manual test", "Matched contract."),
        }
        result_lines = "\n".join(
            f"| {identifier} | {result} | {environment} | {evidence} | {notes} |"
            for identifier, (result, environment, evidence, notes) in rows.items()
        )
        return f"""---
title: Release QA Evidence — {version}
type: qa-evidence
status: active
documentation_version: 1.3
app_version: {version}
last_reviewed: 2026-08-19
tags: [impuls, qa]
evidence_schema: 1
release_commit: {'a' * 40}
release_decision: {decision}
---

# Release QA Evidence — {version}

## Test environments

{qa.ENV_START}
| Environment | Kind | Hardware | macOS | Display / power / devices | TCC state | Evidence note |
| --- | --- | --- | --- | --- | --- | --- |
| MAC-01 | {kind} | generic test Mac | macOS test version | test configuration | explicit test state | reproducible note |
{qa.ENV_END}

## Scenario results

{qa.RESULTS_START}
| ID | Result | Environment | Evidence | Notes |
| --- | --- | --- | --- | --- |
{result_lines}
{qa.RESULTS_END}

## Known gaps

{known_gaps}
"""

    def test_repository_evidence_is_current_and_valid(self):
        policy = qa.load_policy()
        self.assertEqual(qa.validate_repository(policy), [])
        self.assertEqual(qa.release_gate_errors(policy, qa.current_app_version()), [])

    def test_matrix_selects_only_manual_or_mixed_rows(self):
        self.assertEqual(
            set(self.scenarios),
            {"PERM-01", "PWR-02", "REL-04", "MUS-05"},
        )

    def test_enforced_release_rejects_not_recorded(self):
        rows = {
            "PERM-01": ("not-recorded", "NONE", "history", "Missing evidence."),
            "PWR-02": ("pass", "MAC-01", "manual test", "Matched."),
            "REL-04": ("pass", "MAC-01", "manual test", "Matched."),
            "MUS-05": ("pass", "MAC-01", "manual test", "Matched."),
        }
        errors = qa.validate_document(
            "1.4.12",
            self.document(decision="ship-with-known-gaps", rows=rows, known_gaps="- PERM-01 missing."),
            self.scenarios,
            self.policy,
        )
        self.assertTrue(any("not-recorded is forbidden" in error for error in errors))

    def test_certified_release_rejects_unresolved_row(self):
        rows = {
            "PERM-01": ("not-run", "NONE", "pending", "No clean TCC profile available."),
            "PWR-02": ("pass", "MAC-01", "manual test", "Matched."),
            "REL-04": ("pass", "MAC-01", "manual test", "Matched."),
            "MUS-05": ("pass", "MAC-01", "manual test", "Matched."),
        }
        errors = qa.validate_document(
            "1.4.12", self.document(rows=rows), self.scenarios, self.policy
        )
        self.assertTrue(any("certified release contains unresolved" in error for error in errors))

    def test_manual_hardware_pass_requires_hardware_environment(self):
        errors = qa.validate_document(
            "1.4.12",
            self.document(kind="real-mac"),
            self.scenarios,
            self.policy,
        )
        self.assertTrue(any("manual-hardware" in error for error in errors))

    def test_ship_with_known_gaps_requires_gap_section(self):
        rows = {
            "PERM-01": ("not-run", "NONE", "pending", "No clean TCC profile available."),
            "PWR-02": ("pass", "MAC-01", "manual test", "Matched."),
            "REL-04": ("pass", "MAC-01", "manual test", "Matched."),
            "MUS-05": ("pass", "MAC-01", "manual test", "Matched."),
        }
        errors = qa.validate_document(
            "1.4.12",
            self.document(decision="ship-with-known-gaps", rows=rows, known_gaps="- none"),
            self.scenarios,
            self.policy,
        )
        self.assertTrue(any("non-empty ## Known gaps" in error for error in errors))

    def test_release_gate_rejects_blocked_current_release(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            evidence = root / "release-evidence"
            evidence.mkdir()
            matrix = root / "matrix.md"
            matrix.write_text(
                "| ID | Scenario | Mode | Expected contract |\n"
                "| --- | --- | --- | --- |\n"
                "| PERM-01 | Fresh launch | manual-macos | no prompt |\n",
                encoding="utf-8",
            )
            (evidence / "1.4.12.md").write_text(
                self.document(
                    version="1.4.12",
                    decision="blocked",
                    rows={
                        "PERM-01": ("blocked", "MAC-01", "manual test", "Prompt regression."),
                    },
                    known_gaps="- PERM-01 blocks release.",
                ),
                encoding="utf-8",
            )
            policy = qa.Policy(
                enforce_from_version=(1, 4, 12),
                matrix_path=matrix,
                evidence_directory=evidence,
                manual_modes=self.policy.manual_modes,
                result_values=self.policy.result_values,
                release_decisions=self.policy.release_decisions,
                environment_kinds=self.policy.environment_kinds,
            )
            errors = qa.release_gate_errors(policy, "1.4.12")
            self.assertTrue(any("explicitly blocked" in error for error in errors))


if __name__ == "__main__":
    unittest.main()
