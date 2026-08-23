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
        cls.entries = {item["code"]: item for item in cls.registry["locales"]}
        cls.codes = [item["code"] for item in cls.registry["locales"]]
        cls.generated_codes = [code for code in cls.codes if code != cls.registry["default_locale"]]
        cls.configs = {
            code: json.loads((ROOT / "Scripts" / "site-locales" / f"{code}.json").read_text(encoding="utf-8"))
            for code in cls.generated_codes
        }
        cls.pages = {code: BUILDER.build(cls.localized_source, cfg) for code, cfg in cls.configs.items()}

    def test_wave_three_registry_matches_all_shipped_app_languages(self):
        self.assertEqual(self.codes, ["ru", "en", "de", "fr", "es", "ja", "zh-Hans"])
        self.assertEqual(self.registry["default_locale"], "ru")
        self.assertEqual(len({x["path"] for x in self.registry["locales"]}), 7)
        self.assertEqual(self.entries["zh-Hans"]["path"], "zh-hans/")

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
            self.assertIn(f'aria-current="page">{self.entries[code]["label"]}</a>', self.pages[code])

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

    def test_japanese_page_is_real_static_localized_content(self):
        page = self.pages["ja"]
        self.assertIn('<title>IMPULS for macOS – クリップボード', page)
        self.assertIn('IMPULS – 必要なものを画面上端に', page)
        self.assertIn('7 言語対応', page)
        self.assertIn('Impuls はどの言語に対応していますか？', page)
        self.assertIn('href="https://tumanovnv.github.io/impuls/ja/"', page)
        self.assertIn('../assets/screens/en/actions.png', page)
        self.assertNotIn('data-i="hero.h1">ИМПУЛЬС', page)

    def test_simplified_chinese_page_is_real_static_localized_content(self):
        page = self.pages["zh-Hans"]
        self.assertIn('<html lang="zh-Hans">', page)
        self.assertIn('<title>IMPULS for macOS – 剪贴板', page)
        self.assertIn('IMPULS – 把常用工具放在屏幕顶端', page)
        self.assertIn('支持 7 种语言', page)
        self.assertIn('Impuls 支持哪些语言？', page)
        self.assertIn('href="https://tumanovnv.github.io/impuls/zh-hans/"', page)
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
            self.assertEqual(app["@id"], BUILDER.SITE + self.entries[code]["path"] + "#software")
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
        for code in ("de", "fr", "es", "ja", "zh-Hans"):
            cfg = self.configs[code]
            self.assertNotIn("source_dictionary", cfg)
            words, alts = BUILDER.resolve_content(self.localized_source, cfg)
            self.assertEqual(set(words), source_keys, code)
            self.assertEqual(set(alts), screenshot_keys, code)

    def test_wave_two_and_three_external_locales_have_no_dead_translation_keys(self):
        source_keys = BUILDER.translatable_keys(self.localized_source)
        for code in ("fr", "es", "ja", "zh-Hans"):
            self.assertEqual(set(self.configs[code]["strings"]), source_keys, code)

    def test_only_documented_legacy_dead_translation_keys_are_tolerated(self):
        source_keys = BUILDER.translatable_keys(self.localized_source)
        raw_de = set(self.configs["de"]["strings"])
        raw_en = set(BUILDER.read_embedded_dict(self.localized_source, "EN"))
        self.assertEqual(raw_de - source_keys, BUILDER.LEGACY_UNUSED_STRING_KEYS)
        self.assertEqual(raw_en - source_keys, BUILDER.LEGACY_UNUSED_STRING_KEYS)

    def test_multiline_power_screenshot_is_part_of_alt_parity_and_is_localized(self):
        self.assertIn("power", BUILDER.screenshot_keys(self.localized_source))
        for code in ("de", "fr", "es", "ja", "zh-Hans"):
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
        for code, cfg in self.configs.items():
            self.assertEqual(cfg["path"], self.entries[code]["path"])
            self.assertEqual(cfg["og_locale"], self.entries[code]["og_locale"])

    def test_legacy_query_routing_uses_registry_paths_not_locale_codes(self):
        self.assertIn('"zh-Hans":"zh-hans/"', self.localized_source)
        self.assertIn('location.replace(legacyRoutes[legacyLang]);', self.localized_source)
        self.assertNotIn("location.replace(legacyLang + '/');", self.localized_source)

    def test_seven_locale_mobile_selector_remains_no_javascript_and_scrollable(self):
        self.assertIn('Seven page locales no longer fit as a fixed row', self.localized_source)
        self.assertIn('.lang{max-width:48vw;overflow-x:auto;', self.localized_source)
        self.assertIn('@media(max-width:359px)', self.localized_source)


if __name__ == "__main__":
    unittest.main()
