import importlib.util
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Scripts" / "check-localization.py"
SPEC = importlib.util.spec_from_file_location("localization_check", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
CHECKER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECKER)


class LocalizationCheckTests(unittest.TestCase):
    def test_the_repository_passes_its_own_localization_check(self):
        code, problems = CHECKER.collect_code_keys()
        tables = CHECKER.collect_tables()

        self.assertEqual([], problems)
        self.assertTrue(tables, "no Localizable.strings tables were found")
        for name, keys in tables.items():
            self.assertEqual(set(), code - keys, f"{name} is missing keys used in code")

    def test_every_table_carries_the_same_keys(self):
        tables = CHECKER.collect_tables()
        union = set().union(*tables.values())
        for name, keys in tables.items():
            self.assertEqual(set(), union - keys, f"{name} is missing keys another table has")

    def test_a_key_reached_through_a_stored_property_is_still_collected(self):
        """The 1.4.11 regression: `AppFeature` resolves `localized(detailKey)`,
        so a literal-only scan could not see the key at all."""
        code, _ = CHECKER.collect_code_keys()

        self.assertIn("Search local snippets, clipboard items and practical conversions.", code)
        self.assertIn("Control the music source you explicitly selected.", code)

    def test_a_key_chosen_by_a_ternary_is_collected_from_both_branches(self):
        span = '(isEmpty ? "Nothing pinned yet" : "Pinned")'
        self.assertEqual(
            ["Nothing pinned yet", "Pinned"],
            CHECKER.keys_from_call(span[1:-1]),
        )

    def test_only_the_first_literal_of_a_formatted_call_is_a_key(self):
        self.assertEqual(["%@ of %@"], CHECKER.keys_from_call('"%@ of %@", formatTime(a), formatTime(b)'))

    def test_an_argument_span_survives_a_nested_call(self):
        text = 'let value = localized("%@ of %@", formatTime(media.duration)) + suffix'
        start = text.index("localized(") + len("localized")
        self.assertEqual(
            '"%@ of %@", formatTime(media.duration)',
            CHECKER.argument_span(text, start),
        )

    def test_escapes_are_interpreted_the_same_way_on_both_sides(self):
        """The old check unescaped table keys but not code keys, so the first
        key containing a newline would have been reported missing while present."""
        self.assertEqual("a\nb", CHECKER.unescape(r"a\nb"))
        self.assertEqual('say "hi"', CHECKER.unescape(r"say \"hi\""))


if __name__ == "__main__":
    unittest.main()
