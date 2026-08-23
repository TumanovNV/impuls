import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WORKFLOWS = (
    ROOT / ".github" / "workflows" / "site-localization.yml",
    ROOT / ".github" / "workflows" / "site-release-sync.yml",
)


class SiteLocalizationWorkflowTests(unittest.TestCase):
    def test_locale_path_variable_never_overwrites_shell_path(self):
        for workflow in WORKFLOWS:
            text = workflow.read_text(encoding="utf-8")
            self.assertNotIn("read -r CODE PATH", text, workflow.name)
            self.assertIn("LOCALE_PATH", text, workflow.name)


if __name__ == "__main__":
    unittest.main()
