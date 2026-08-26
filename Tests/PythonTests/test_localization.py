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


class NativeProviderCopyTests(unittest.TestCase):
    """Native empty-state copy has to stay one whole sentence per provider.

    IMP-11 replaced the Apple-Music-specific wording with a single `%@`
    template shared by Apple Music and Spotify. Russian inflects the predicate
    for the subject's gender, so one template cannot be right for both: the
    shipped result was "Apple Music открыто" (previously the correct
    "Apple Music открыта") and "Spotify не установлено" instead of
    "не установлен". `check-localization.py` verifies that used keys exist; it
    cannot see grammar, so this is the structural guard that keeps the
    provider-specific keys in place.
    """

    FAMILIES = [
        ("Apple Music is not installed.", "Spotify is not installed."),
        ("Open Apple Music and start a track.", "Open Spotify and start a track."),
        ("Apple Music is open, but no track is playing.",
         "Spotify is open, but no track is playing."),
        ("Apple Music is playing, but its track data could not be read.",
         "Spotify is playing, but its track data could not be read."),
        ("Open Apple Music", "Open Spotify"),
    ]

    RETIRED_TEMPLATES = [
        "Open %@",
        "%@ is not installed.",
        "Open %@ and start a track.",
        "%@ is open, but no track is playing.",
        "%@ is playing, but its track data could not be read.",
    ]

    def test_each_native_provider_owns_its_whole_sentence_in_every_table(self):
        tables = CHECKER.collect_tables()
        self.assertTrue(tables)
        for name, keys in tables.items():
            for apple_key, spotify_key in self.FAMILIES:
                self.assertIn(apple_key, keys, f"{name} lost the Apple Music wording")
                self.assertIn(spotify_key, keys, f"{name} lost the Spotify wording")

    def test_the_shared_placeholder_templates_are_gone(self):
        """Deleting the keys is what makes the regression unshippable: reverting
        the pane to `localized("%@ is open…", name)` then fails the localization
        gate outright, because the key no longer exists in any table."""
        tables = CHECKER.collect_tables()
        self.assertTrue(tables, "no Localizable.strings tables were found")
        for name, keys in tables.items():
            for template in self.RETIRED_TEMPLATES:
                self.assertNotIn(
                    template, keys,
                    f"{name} still carries the shared template {template!r}")

    def test_russian_agrees_with_each_product_name(self):
        """The exact regression, pinned. Apple Music is feminine in Russian and
        Spotify is masculine, so the two sentences cannot share an ending."""
        table = self._russian()
        self.assertEqual(
            "Apple Music открыта, но воспроизведение не запущено.",
            table["Apple Music is open, but no track is playing."])
        self.assertEqual(
            "Spotify открыт, но воспроизведение не запущено.",
            table["Spotify is open, but no track is playing."])
        self.assertEqual("Apple Music не установлена.", table["Apple Music is not installed."])
        self.assertEqual("Spotify не установлен.", table["Spotify is not installed."])

    def _russian(self):
        path = ROOT / "Resources" / "ru.lproj" / "Localizable.strings"
        pairs = {}
        for line in path.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line.startswith('"') or " = " not in line:
                continue
            key, _, value = line.partition(" = ")
            pairs[CHECKER.unescape(key.strip()[1:-1])] = CHECKER.unescape(
                value.strip().rstrip(";")[1:-1])
        return pairs


if __name__ == "__main__":
    unittest.main()
