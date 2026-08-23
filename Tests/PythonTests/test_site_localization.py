import importlib.util
import json
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "docs" / "index.html"
SITEMAP_PATH = ROOT / "docs" / "sitemap.xml"


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    spec.loader.exec_module(module)
    return module


SYNC = load_module("sync_site_locales", ROOT / "Scripts" / "sync-site-locales.py")
SITEMAP = load_module("sync_site_sitemap", ROOT / "Scripts" / "sync-site-sitemap.py")
BUILDER = load_module("build_site_locale", ROOT / "Scripts" / "build-site-locale.py")


class SiteLocalizationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = SOURCE.read_text(encoding="utf-8")
        cls.localized_source = SYNC.rewrite(cls.source)
        cls.sitemap = SITEMAP.rewrite(SITEMAP_PATH.read_text(encoding="utf-8"))
        cls.registry = BUILDER.REGISTRY
        cls.codes = [item["code"] for item in cls.registry["locales"]]
        cls.generated_codes = [code for code in cls.codes if code != cls.registry["default_locale"]]
        cls.configs = {
            code: json.loads((ROOT / "Scripts" / "site-locales" / f"{code}.json").read_text(encoding="utf-8"))
            for code in cls.generated_codes
        }
        cls.pages = {code: BUILDER.build(cls.localized_source, cfg) for code, cfg in cls.configs.items()}

    def test_wave_two_registry_is_ru_en_de_fr_es(self):
        self.assertEqual(self.codes, ["ru", "en", "de", "fr", "es"])
        self.assertEqual(self.registry["default_locale"], "ru")
        self.assertEqual(len({x["path"] for x in self.registry["locales"]}), 5)

    def test_locale_source_sync_is_idempotent(self):
        self.assertEqual(SYNC.rewrite(self.localized_source), self.localized_source)
        self.assertEqual(self.localized_source.count("function runtimeLabels(){"), 1)

    def test_sitemap_sync_is_idempotent_and_registry_driven(self):
        self.assertEqual(SITEMAP.rewrite(self.sitemap), self.sitemap)
        for item in self.registry["locales"]:
            self.assertIn(f"<loc>{BUILDER.SITE}{item['path']}</loc>", self.sitemap)
        self.assertIn("site-privacy.html", self.sitemap)

    def test_complete_hreflang_cluster_is_present_on_every_page(self):
        for page in [self.localized_source, *self.pages.values()]:
            for code in self.codes:
                self.assertIn(f'hreflang="{code}"', page)
            self.assertIn('hreflang="x-default"', page)

    def test_every_generated_locale_uses_one_builder_and_selector(self):
        for code in self.generated_codes:
            self.assertIn(f'<html lang="{self.configs[code]["html_lang"]}">', self.pages[code])
            self.assertIn(f'window.IMPULS_LANG="{code}"', self.pages[code])
            self.assertIn(f'aria-current="page">{next(x["label"] for x in self.registry["locales"] if x["code"] == code)}</a>', self.pages[code])

    def test_french_page_is_real_static_localized_content(self):
        page = self.pages["fr"]
        self.assertIn('<title>IMPULS pour macOS', page)
        self.assertIn('IMPULS – l’essentiel au bord supérieur de l’écran', page)
        self.assertIn('7 langues', page)
        self.assertIn('Quelles langues Impuls prend-il en charge ?', page)
        self.assertIn('href="https://tumanovnv.github.io/impuls/fr/"', page)
        self.assertIn('../assets/screens/en/actions.png', page)
        self.assertNotIn('data-i="hero.h1">ИМПУЛЬС', page)

    def test_spanish_page_is_real_static_localized_content(self):
        page = self.pages["es"]
        self.assertIn('<title>IMPULS para macOS', page)
        self.assertIn('IMPULS – lo esencial en el borde superior de la pantalla', page)
        self.assertIn('7 idiomas', page)
        self.assertIn('¿Qué idiomas admite Impuls?', page)
        self.assertIn('href="https://tumanovnv.github.io/impuls/es/"', page)
        self.assertIn('../assets/screens/en/actions.png', page)
        self.assertNotIn('data-i="hero.h1">ИМПУЛЬС', page)

    def test_structured_data_uses_complete_registry_and_current_release(self):
        for code, page in self.pages.items():
            match = re.search(
                r'<script type="application/ld\+json" id="software-schema">(.*?)</script>',
                page,
                re.S,
            )
            self.assertIsNotNone(match)
            schema = json.loads(match.group(1))
            graph = schema["@graph"]
            website = next(item for item in graph if item.get("@type") == "WebSite")
            app = next(item for item in graph if item.get("@type") == "SoftwareApplication")
            faq = next(item for item in graph if item.get("@type") == "FAQPage")
            self.assertEqual(website["inLanguage"], self.codes)
            self.assertEqual(app["inLanguage"], code)
            self.assertEqual(app["softwareVersion"], "1.4.15")
            self.assertTrue(app["@id"].endswith(f"/{code}/#software"))
            self.assertEqual(len(faq["mainEntity"]), 6)

    def test_open_graph_locale_cluster_excludes_current_locale_from_alternates(self):
        for code, page in self.pages.items():
            main = re.search(r'<meta property="og:locale" content="([^"]+)">', page).group(1)
            alternates = re.findall(r'<meta property="og:locale:alternate" content="([^"]+)">', page)
            self.assertNotIn(main, alternates, code)
            self.assertEqual(len(alternates), len(self.codes) - 1, code)

    def test_external_locale_dictionaries_have_exact_effective_source_parity(self):
        source_keys = BUILDER.translatable_keys(self.localized_source)
        screenshot_keys = BUILDER.screenshot_keys(self.localized_source)
        for code in ("de", "fr", "es"):
            cfg = self.configs[code]
            self.assertNotIn("source_dictionary", cfg)
            words, alts = BUILDER.resolve_content(self.localized_source, cfg)
            self.assertEqual(set(words), source_keys, code)
            self.assertEqual(set(alts), screenshot_keys, code)

    def test_french_and_spanish_have_no_dead_translation_keys(self):
        source_keys = BUILDER.translatable_keys(self.localized_source)
        for code in ("fr", "es"):
            self.assertEqual(set(self.configs[code]["strings"]), source_keys, code)

    def test_only_documented_legacy_dead_translation_keys_are_tolerated(self):
        source_keys = BUILDER.translatable_keys(self.localized_source)
        raw_de = set(self.configs["de"]["strings"])
        raw_en = set(BUILDER.read_embedded_dict(self.localized_source, "EN"))
        self.assertEqual(raw_de - source_keys, BUILDER.LEGACY_UNUSED_STRING_KEYS)
        self.assertEqual(raw_en - source_keys, BUILDER.LEGACY_UNUSED_STRING_KEYS)

    def test_multiline_power_screenshot_is_part_of_alt_parity_and_is_localized(self):
        self.assertIn("power", BUILDER.screenshot_keys(self.localized_source))
        for code in ("de", "fr", "es"):
            cfg = self.configs[code]
            self.assertIn("power", cfg["alts"])
            power = re.search(
                r'<img\b(?=[^>]*data-shot="power")[^>]*alt="([^"]+)"',
                self.pages[code],
                re.I | re.S,
            )
            self.assertIsNotNone(power)
            self.assertEqual(power.group(1), cfg["alts"]["power"])

    def test_locale_configs_match_registry_path_and_open_graph_locale(self):
        entries = {item["code"]: item for item in self.registry["locales"]}
        for code, cfg in self.configs.items():
            self.assertEqual(cfg["path"], entries[code]["path"])
            self.assertEqual(cfg["og_locale"], entries[code]["og_locale"])


if __name__ == "__main__":
    unittest.main()
