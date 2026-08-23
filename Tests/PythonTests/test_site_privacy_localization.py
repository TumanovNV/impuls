import importlib.util
import json
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    spec.loader.exec_module(module)
    return module


BUILDER = load_module("build_site_privacy_locale", ROOT / "Scripts" / "build-site-privacy-locale.py")
LINKS = load_module("sync_site_privacy_links", ROOT / "Scripts" / "sync-site-privacy-links.py")
SITEMAP = load_module("sync_site_sitemap_legal", ROOT / "Scripts" / "sync-site-sitemap.py")
LEGACY = load_module("sync_site_privacy_legacy", ROOT / "Scripts" / "sync-site-privacy-legacy.py")


class SitePrivacyLocalizationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.registry = BUILDER.load_registry()
        cls.codes = [item["code"] for item in cls.registry["locales"]]
        cls.entries = {item["code"]: item for item in cls.registry["locales"]}
        cls.configs = {
            code: json.loads((ROOT / "Scripts" / "site-privacy-locales" / f"{code}.json").read_text(encoding="utf-8"))
            for code in cls.codes
        }
        cls.pages = {code: BUILDER.render(cls.configs[code], cls.registry) for code in cls.codes}

    def test_registry_has_seven_unique_privacy_routes(self):
        self.assertEqual(self.codes, ["ru", "en", "de", "fr", "es", "ja", "zh-Hans"])
        paths = [self.entries[code]["privacy_path"] for code in self.codes]
        self.assertEqual(len(paths), len(set(paths)))
        self.assertEqual(self.entries["ru"]["privacy_path"], "privacy/")
        self.assertEqual(self.entries["zh-Hans"]["privacy_path"], "zh-hans/privacy/")

    def test_every_privacy_config_matches_registry_and_nine_section_contract(self):
        for code in self.codes:
            cfg = self.configs[code]
            self.assertEqual(cfg["privacy_path"], self.entries[code]["privacy_path"], code)
            self.assertEqual([s["id"] for s in cfg["sections"]], BUILDER.EXPECTED_SECTIONS, code)
            self.assertEqual([t["id"] for t in cfg["toc"]], BUILDER.EXPECTED_SECTIONS, code)

    def test_every_page_has_self_canonical_and_full_reciprocal_hreflang(self):
        for code, page in self.pages.items():
            self.assertIn(f'<link rel="canonical" href="{BUILDER.SITE}{self.entries[code]["privacy_path"]}">', page, code)
            for target in self.codes:
                self.assertIn(f'hreflang="{target}"', page, (code, target))
                self.assertIn(BUILDER.SITE + self.entries[target]["privacy_path"], page, (code, target))
            self.assertIn('hreflang="x-default"', page, code)

    def test_policy_revision_and_controller_are_consistent(self):
        for code, page in self.pages.items():
            self.assertIn("3.0", page, code)
            self.assertIn("2026", page, code)
            self.assertIn("Nikolay Vitalyevich Tumanov", page, code)
            self.assertIn("github.com/TumanovNV/impuls/issues/new/choose", page, code)

    def test_actual_product_privacy_boundaries_are_present_in_every_translation(self):
        for code, page in self.pages.items():
            self.assertIn("GitHub", page, code)
            self.assertIn("365", page, code)
            self.assertIn("HMAC", page, code)
            self.assertIn("PRIVACY.md", page, code)
            self.assertIn("GDPR", page, code)

    def test_russian_and_english_pages_state_non_certification_and_mandatory_rights(self):
        self.assertIn("не является заявлением о сертификации", self.pages["ru"])
        self.assertIn("обязательные права", self.pages["ru"])
        self.assertIn("not a certification", self.pages["en"])
        self.assertIn("mandatory privacy rights", self.pages["en"])

    def test_github_pages_security_ip_fact_is_disclosed(self):
        self.assertIn("IP‑адрес посетителя регистрируется и хранится в целях безопасности", self.pages["ru"])
        self.assertIn("IP address is logged and stored for security purposes", self.pages["en"])

    def test_landing_privacy_cta_migrates_to_localized_route(self):
        source = (ROOT / "docs" / "index.html").read_text(encoding="utf-8")
        rewritten = LINKS.rewrite(source)
        self.assertIn('href="privacy/"><span data-i="p.doc">', rewritten)
        self.assertNotIn('href="site-privacy.html"><span data-i="p.doc">', rewritten)

    def test_sitemap_projects_all_privacy_routes_and_drops_legacy_url(self):
        source = (ROOT / "docs" / "sitemap.xml").read_text(encoding="utf-8")
        rewritten = SITEMAP.rewrite(source)
        for code in self.codes:
            self.assertIn(f"<loc>{BUILDER.SITE}{self.entries[code]['privacy_path']}</loc>", rewritten, code)
        self.assertNotIn("<loc>https://tumanovnv.github.io/impuls/site-privacy.html</loc>", rewritten)

    def test_legacy_url_is_noindex_handoff_to_russian_canonical(self):
        self.assertIn('content="noindex,follow"', LEGACY.PAGE)
        self.assertIn('href="https://tumanovnv.github.io/impuls/privacy/"', LEGACY.PAGE)
        self.assertIn('http-equiv="refresh"', LEGACY.PAGE)


if __name__ == "__main__":
    unittest.main()
