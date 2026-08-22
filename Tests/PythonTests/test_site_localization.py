import importlib.util
import json
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "docs" / "index.html"


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    spec.loader.exec_module(module)
    return module


SYNC = load_module("sync_site_locales", ROOT / "Scripts" / "sync-site-locales.py")
BUILDER = load_module("build_site_locale", ROOT / "Scripts" / "build-site-locale.py")


class SiteLocalizationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = SOURCE.read_text(encoding="utf-8")
        cls.localized_source = SYNC.rewrite(cls.source)
        cls.configs = {
            code: json.loads((ROOT / "Scripts" / "site-locales" / f"{code}.json").read_text(encoding="utf-8"))
            for code in ("en", "de")
        }
        cls.pages = {code: BUILDER.build(cls.localized_source, cfg) for code, cfg in cls.configs.items()}

    def test_locale_source_sync_is_idempotent(self):
        self.assertEqual(SYNC.rewrite(self.localized_source), self.localized_source)

    def test_complete_hreflang_cluster_is_present_on_every_page(self):
        for page in [self.localized_source, self.pages["en"], self.pages["de"]]:
            self.assertIn('hreflang="ru"', page)
            self.assertIn('hreflang="en"', page)
            self.assertIn('hreflang="de"', page)
            self.assertIn('hreflang="x-default"', page)

    def test_english_and_german_use_one_generator(self):
        self.assertIn('<html lang="en">', self.pages["en"])
        self.assertIn('<html lang="de">', self.pages["de"])
        self.assertIn('window.IMPULS_LANG="en"', self.pages["en"])
        self.assertIn('window.IMPULS_LANG="de"', self.pages["de"])
        self.assertIn('aria-current="page">EN</a>', self.pages["en"])
        self.assertIn('aria-current="page">DE</a>', self.pages["de"])

    def test_german_page_is_real_static_localized_content(self):
        page = self.pages["de"]
        self.assertIn('<title>IMPULS für macOS', page)
        self.assertIn('IMPULS – alles Wichtige am oberen Bildschirmrand', page)
        self.assertIn('7 Sprachen', page)
        self.assertIn('Welche Sprachen unterstützt Impuls?', page)
        self.assertIn('href="https://tumanovnv.github.io/impuls/de/"', page)
        self.assertIn('../assets/screens/en/actions.png', page)
        self.assertNotIn('data-i="hero.h1">ИМПУЛЬС', page)

    def test_german_structured_data_has_localized_language_and_current_release(self):
        match = re.search(
            r'<script type="application/ld\+json" id="software-schema">(.*?)</script>',
            self.pages["de"],
            re.S,
        )
        self.assertIsNotNone(match)
        schema = json.loads(match.group(1))
        graph = schema["@graph"]
        website = next(item for item in graph if item.get("@type") == "WebSite")
        app = next(item for item in graph if item.get("@type") == "SoftwareApplication")
        faq = next(item for item in graph if item.get("@type") == "FAQPage")
        self.assertEqual(website["inLanguage"], ["ru", "en", "de"])
        self.assertEqual(app["inLanguage"], "de")
        self.assertEqual(app["softwareVersion"], "1.4.15")
        self.assertTrue(app["@id"].endswith("/de/#software"))
        self.assertEqual(len(faq["mainEntity"]), 6)
        self.assertEqual(faq["mainEntity"][0]["name"], "Brauche ich ein MacBook mit Displayausschnitt?")

    def test_open_graph_locale_cluster_excludes_current_locale_from_alternates(self):
        for code, page in self.pages.items():
            main = re.search(r'<meta property="og:locale" content="([^"]+)">', page).group(1)
            alternates = re.findall(r'<meta property="og:locale:alternate" content="([^"]+)">', page)
            self.assertNotIn(main, alternates, code)
            self.assertEqual(len(alternates), 2, code)

    def test_external_german_dictionary_has_exact_source_key_parity(self):
        cfg = self.configs["de"]
        self.assertNotIn("source_dictionary", cfg)
        self.assertEqual(set(cfg["strings"]), BUILDER.translatable_keys(self.localized_source))
        self.assertEqual(set(cfg["alts"]), BUILDER.screenshot_keys(self.localized_source))


if __name__ == "__main__":
    unittest.main()
