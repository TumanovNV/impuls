import importlib.util
import unittest
from datetime import date
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Scripts" / "check-documentation-freshness.py"
SPEC = importlib.util.spec_from_file_location("documentation_freshness", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
FRESHNESS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(FRESHNESS)


class DocumentationFreshnessTests(unittest.TestCase):
    def test_manifest_is_valid_against_repository_tree(self):
        entries = FRESHNESS.load_manifest()
        self.assertGreaterEqual(len(entries), 10)

    def test_fresh_document_has_no_reasons(self):
        reasons = FRESHNESS.freshness_reasons(
            source_date=date(2026, 8, 10),
            reviewed_date=date(2026, 8, 19),
            source_is_ancestor_of_doc=True,
            today=date(2026, 8, 19),
            max_review_age_days=180,
            enforce_review_age=True,
        )
        self.assertEqual([], reasons)

    def test_source_date_after_review_is_stale(self):
        reasons = FRESHNESS.freshness_reasons(
            source_date=date(2026, 8, 20),
            reviewed_date=date(2026, 8, 19),
            source_is_ancestor_of_doc=False,
            today=date(2026, 8, 20),
            max_review_age_days=180,
            enforce_review_age=False,
        )
        self.assertTrue(any("after last_reviewed" in reason for reason in reasons))
        self.assertTrue(any("source commit is newer" in reason for reason in reasons))

    def test_same_day_source_change_still_uses_commit_ancestry(self):
        reasons = FRESHNESS.freshness_reasons(
            source_date=date(2026, 8, 19),
            reviewed_date=date(2026, 8, 19),
            source_is_ancestor_of_doc=False,
            today=date(2026, 8, 19),
            max_review_age_days=180,
            enforce_review_age=False,
        )
        self.assertEqual(1, len(reasons))
        self.assertIn("source commit is newer", reasons[0])

    def test_same_commit_review_survives_a_timezone_day_boundary(self):
        # PR #75 committed source and canonical docs together at 00:30 +0300,
        # which `%cs` renders as the next calendar day, while `last_reviewed`
        # held the day the work was actually reviewed. Nothing had drifted.
        reasons = FRESHNESS.freshness_reasons(
            source_date=date(2026, 8, 22),
            reviewed_date=date(2026, 8, 21),
            source_is_ancestor_of_doc=True,
            today=date(2026, 8, 22),
            max_review_age_days=180,
            enforce_review_age=False,
            source_is_doc_commit=True,
        )
        self.assertEqual([], reasons)

    def test_separate_later_source_commit_is_still_stale(self):
        # The case the checker actually exists for: the document did not move
        # with its source. Sharing a calendar day changes nothing here.
        reasons = FRESHNESS.freshness_reasons(
            source_date=date(2026, 8, 22),
            reviewed_date=date(2026, 8, 21),
            source_is_ancestor_of_doc=True,
            today=date(2026, 8, 22),
            max_review_age_days=180,
            enforce_review_age=False,
            source_is_doc_commit=False,
        )
        self.assertEqual(1, len(reasons))
        self.assertIn("after last_reviewed", reasons[0])

    def test_same_commit_does_not_excuse_a_future_review_date(self):
        reasons = FRESHNESS.freshness_reasons(
            source_date=date(2026, 8, 22),
            reviewed_date=date(2026, 8, 23),
            source_is_ancestor_of_doc=True,
            today=date(2026, 8, 22),
            max_review_age_days=180,
            enforce_review_age=False,
            source_is_doc_commit=True,
        )
        self.assertEqual(1, len(reasons))
        self.assertIn("future", reasons[0])

    def test_same_commit_still_obeys_the_review_age_policy(self):
        reasons = FRESHNESS.freshness_reasons(
            source_date=date(2026, 1, 1),
            reviewed_date=date(2025, 12, 31),
            source_is_ancestor_of_doc=True,
            today=date(2026, 8, 22),
            max_review_age_days=180,
            enforce_review_age=True,
            source_is_doc_commit=True,
        )
        self.assertEqual(1, len(reasons))
        self.assertIn("review age", reasons[0])

    def test_age_policy_is_only_enforced_when_requested(self):
        common = dict(
            source_date=date(2026, 1, 1),
            reviewed_date=date(2026, 1, 1),
            source_is_ancestor_of_doc=True,
            today=date(2026, 8, 19),
            max_review_age_days=180,
        )
        self.assertEqual(
            [],
            FRESHNESS.freshness_reasons(**common, enforce_review_age=False),
        )
        reasons = FRESHNESS.freshness_reasons(**common, enforce_review_age=True)
        self.assertEqual(1, len(reasons))
        self.assertIn("review age", reasons[0])

    def test_future_review_date_is_rejected(self):
        reasons = FRESHNESS.freshness_reasons(
            source_date=date(2026, 8, 19),
            reviewed_date=date(2026, 8, 20),
            source_is_ancestor_of_doc=True,
            today=date(2026, 8, 19),
            max_review_age_days=180,
            enforce_review_age=False,
        )
        self.assertEqual(1, len(reasons))
        self.assertIn("future", reasons[0])


if __name__ == "__main__":
    unittest.main()
