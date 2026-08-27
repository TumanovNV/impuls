"""Static regression coverage for the Developer ID / notarization release contract.

Real Apple notarization cannot be exercised here: it needs credentials this
repository deliberately does not hold, and a fake submission would be evidence of
nothing. What *can* be checked deterministically is the shape of the pipeline —
that the trigger cannot re-publish on a workflow edit, that the signing path is
fail-closed, that the keychain is ephemeral and cleaned up, and that nothing
rebuilds the application after Apple has notarized it.

Plain-text assertions rather than a YAML parse, following
test_site_localization_workflows.py: PyYAML is not a dependency of this
repository and the contract being protected is literal command text anyway.
"""

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github" / "workflows" / "release.yml"
DMG = ROOT / "Scripts" / "dmg.sh"
VERSION_FILE = ROOT / "Scripts" / "version"


def executable_text(source: str) -> str:
    """`source` with comment-only lines removed.

    Absence assertions have to run against commands rather than prose. A comment
    explaining why the login keychain is never touched contains the very string
    such an assertion searches for, and would fail the check it documents.
    """
    return "\n".join(
        line for line in source.splitlines() if not line.lstrip().startswith("#")
    )


REQUIRED_SECRETS = (
    "IMPULS_DEVELOPER_ID_P12_BASE64",
    "IMPULS_DEVELOPER_ID_P12_PASSWORD",
    "IMPULS_DEVELOPER_ID_APPLICATION",
    "APPLE_ID",
    "APPLE_TEAM_ID",
    "APPLE_APP_SPECIFIC_PASSWORD",
    "SPARKLE_EDDSA_PRIVATE_KEY",
)


class ReleaseTriggerTests(unittest.TestCase):
    """A change to the release workflow must not ship the current version."""

    @classmethod
    def setUpClass(cls):
        cls.text = WORKFLOW.read_text(encoding="utf-8")

    def push_paths(self) -> list[str]:
        block = re.search(
            r"\n  push:\n(?:.*\n)*?    paths:\n((?:      - .*\n)+)", self.text
        )
        assert block is not None, "release.yml has no push paths block"
        return [line.strip().removeprefix("- ") for line in block.group(1).splitlines()]

    def test_push_trigger_watches_the_version_file(self):
        self.assertIn("Scripts/version", self.push_paths())

    def test_push_trigger_does_not_watch_the_workflow_itself(self):
        # The historical trigger included this path, so editing the release
        # pipeline re-issued a production release of whatever version happened
        # to be current.
        self.assertNotIn(".github/workflows/release.yml", self.push_paths())

    def test_manual_publication_is_an_opt_in_boolean_defaulting_to_false(self):
        block = re.search(
            r"      publish_release:\n((?:        .*\n)+)", self.text
        )
        self.assertIsNotNone(block, "workflow_dispatch has no publish_release input")
        self.assertIn("type: boolean", block.group(1))
        self.assertIn("default: false", block.group(1))
        self.assertNotIn("default: true", block.group(1))


class ReleasePublicationGateTests(unittest.TestCase):
    """Publication is a separate, explicitly gated, least-privileged job."""

    @classmethod
    def setUpClass(cls):
        cls.text = WORKFLOW.read_text(encoding="utf-8")

    def publish_job(self) -> str:
        return self.text.partition("\n  publish:\n")[2]

    def build_job(self) -> str:
        return self.text.partition("\n  release:\n")[2].partition("\n  publish:\n")[0]

    def test_release_job_cannot_write_to_the_repository(self):
        # Everything up to publication runs with read-only permissions, so no
        # signing or notarization step can create a tag or a release.
        self.assertRegex(self.build_job(), r"permissions:\n      contents: read\n")

    def test_publication_is_gated_on_the_explicit_input(self):
        gate = self.publish_job().partition("runs-on:")[0]
        self.assertIn("needs: release", gate)
        self.assertIn("inputs.publish_release", gate)
        self.assertIn("github.event_name == 'push'", gate)

    def test_publication_only_happens_from_main(self):
        gate = self.publish_job().partition("runs-on:")[0]
        self.assertIn("github.ref == 'refs/heads/main'", gate)

    def test_a_release_candidate_never_creates_a_github_release(self):
        # `gh release create`/`edit`/`upload` must exist only inside the gated
        # publish job; a manual run with publish_release off stops before it.
        self.assertNotIn("gh release", self.build_job())
        self.assertIn("gh release create", self.publish_job())

    def test_only_the_publish_job_may_write(self):
        self.assertRegex(self.publish_job(), r"permissions:\n      contents: write\n")
        self.assertEqual(1, self.text.count("contents: write"))


class DeveloperIdCredentialTests(unittest.TestCase):
    """The production path fails closed instead of falling back to ad-hoc."""

    @classmethod
    def setUpClass(cls):
        cls.text = WORKFLOW.read_text(encoding="utf-8")

    def test_every_required_secret_is_consumed(self):
        for secret in REQUIRED_SECRETS:
            self.assertIn(f"secrets.{secret}", self.text, secret)

    def test_missing_credentials_stop_the_release_before_it_builds(self):
        gate = self.text.index("Require Apple signing and notarization credentials")
        build = self.text.index("Build the Developer ID signed application")
        self.assertLess(gate, build)
        for secret in REQUIRED_SECRETS:
            self.assertIn(secret, self.text[gate:build], secret)

    def test_production_release_cannot_fall_back_to_an_ad_hoc_signature(self):
        # `--sign -` is bundle.sh's local-development branch. If it ever appears
        # here the release path has grown a silent downgrade.
        commands = executable_text(self.text)
        self.assertNotIn("--sign -", commands)
        # The transitional entitlements may be named only by the existing
        # security-boundary check, which greps them for the Apple Events key.
        # Handing them to codesign on this path would disable Library Validation
        # on a released artifact.
        for line in commands.splitlines():
            if "Impuls.AdHoc.entitlements" in line:
                self.assertIn("grep", line, line.strip())
        self.assertIn("An ad-hoc signature reached the production release path", self.text)

    def test_the_signed_application_is_verified_as_developer_id(self):
        self.assertIn('"Developer ID Application: "*', self.text)
        self.assertIn("disable-library-validation", self.text)


class EphemeralKeychainTests(unittest.TestCase):
    """The certificate lives in a throwaway keychain and never outlives the job."""

    @classmethod
    def setUpClass(cls):
        cls.text = WORKFLOW.read_text(encoding="utf-8")

    def test_certificate_is_imported_into_a_temporary_keychain(self):
        self.assertIn("security create-keychain", self.text)
        self.assertIn("security set-keychain-settings", self.text)
        self.assertIn("security unlock-keychain", self.text)
        self.assertIn("security import", self.text)
        self.assertIn("security set-key-partition-list", self.text)
        self.assertIn('KEYCHAIN="$RUNNER_TEMP/impuls-signing.keychain-db"', self.text)

    def test_the_login_keychain_is_never_the_import_target(self):
        # The runner's own keychain must never hold the Developer ID key: it
        # outlives the job on a self-hosted runner and is not ours to write to.
        self.assertNotIn("login.keychain", executable_text(self.text))

    def test_the_keychain_is_deleted_even_when_the_job_fails(self):
        cleanup = self.text.partition("Remove the ephemeral signing keychain")[2]
        self.assertIn("if: always()", cleanup)
        self.assertIn("security delete-keychain", cleanup)
        # A decoded .p12 must not survive a step that died mid-import.
        self.assertIn("-name '*.p12' -delete", cleanup)

    def test_secret_material_is_never_echoed(self):
        # `set -x` would expand every secret into the log.
        commands = executable_text(self.text)
        self.assertNotIn("set -x", commands)
        self.assertNotIn("set -euxo", commands)
        for secret in REQUIRED_SECRETS:
            self.assertNotIn(f'echo "${secret}"', commands, secret)
            self.assertNotIn(f"echo ${secret}", commands, secret)


class NotarizationSequenceTests(unittest.TestCase):
    """Submit, wait, staple, validate — and stop on rejection."""

    @classmethod
    def setUpClass(cls):
        cls.text = WORKFLOW.read_text(encoding="utf-8")

    def test_submission_waits_for_apple(self):
        self.assertIn("xcrun notarytool submit", self.text)
        self.assertIn("--wait", self.text)

    def test_both_the_application_and_the_disk_image_are_notarized(self):
        self.assertEqual(2, self.text.count("xcrun notarytool submit"))

    def test_a_rejected_submission_fails_the_job(self):
        self.assertIn('!= "Accepted"', self.text)
        self.assertIn("xcrun notarytool log", self.text)

    def test_tickets_are_stapled_and_validated(self):
        self.assertIn("xcrun stapler staple", self.text)
        self.assertIn("xcrun stapler validate", self.text)

    def test_gatekeeper_assessment_runs_on_the_final_artifacts(self):
        self.assertIn("spctl --assess --type exec", self.text)
        self.assertIn("spctl --assess --type open", self.text)


class ArtifactIdentityTests(unittest.TestCase):
    """One application goes through Apple, and that is the one users receive."""

    @classmethod
    def setUpClass(cls):
        cls.text = WORKFLOW.read_text(encoding="utf-8")

    def test_the_application_is_built_exactly_once(self):
        self.assertEqual(1, self.text.count("./Scripts/bundle.sh"))

    def test_packaging_never_rebuilds_the_notarized_application(self):
        # dmg.sh runs bundle.sh unless told not to. A bare invocation here would
        # silently replace the stapled bundle with a fresh, unnotarized one.
        invocations = re.findall(r"\./Scripts/dmg\.sh[^\n]*", self.text)
        self.assertTrue(invocations, "release.yml no longer packages a disk image")
        for invocation in invocations:
            self.assertIn("--no-build", invocation)

    def test_the_update_archive_is_built_after_stapling(self):
        staple = self.text.index("xcrun stapler staple")
        zip_creation = self.text.index("ditto -c -k --keepParent \"$APP\" \"$ZIP\"")
        self.assertLess(staple, zip_creation)

    def test_the_notarized_code_directory_hash_is_carried_through(self):
        # Recorded once at signing time and re-compared against the build
        # directory, the extracted ZIP and the application inside the DMG.
        self.assertIn("IMPULS_APP_CDHASH", self.text)
        self.assertGreaterEqual(self.text.count('= "$IMPULS_APP_CDHASH"'), 4)

    def test_published_assets_are_the_verified_artifacts(self):
        publish = self.text.partition("\n  publish:\n")[2]
        self.assertIn("sha256sum", publish)
        self.assertIn("does not match the checksum recorded by the release job", publish)


class SparkleTrustLayerTests(unittest.TestCase):
    """Developer ID does not replace the independent update trust chain."""

    @classmethod
    def setUpClass(cls):
        cls.text = WORKFLOW.read_text(encoding="utf-8")

    def test_appcast_is_generated_and_verified(self):
        self.assertIn("generate_appcast", self.text)
        self.assertIn("sign_update", self.text)
        self.assertIn("--ed-key-file - --verify", self.text)
        self.assertIn("sparkle:edSignature=", self.text)


class DmgPackagingContractTests(unittest.TestCase):
    """`--no-build` packages an existing bundle; the default still builds."""

    @classmethod
    def setUpClass(cls):
        cls.text = DMG.read_text(encoding="utf-8")

    def test_no_build_is_supported(self):
        self.assertIn("--no-build", self.text)

    def test_default_invocation_still_builds(self):
        self.assertIn("BUILD_APP=1", self.text)
        self.assertIn('"$ROOT/Scripts/bundle.sh" release', self.text)

    def test_no_build_refuses_a_missing_application(self):
        self.assertIn("--no-build requires an existing", self.text)

    def test_an_unknown_flag_is_rejected(self):
        self.assertIn("usage:", self.text)


class ReleaseScopeTests(unittest.TestCase):
    """This change prepares the release contour; it does not perform a release."""

    def test_version_is_not_bumped_by_this_work(self):
        self.assertEqual("VERSION=1.4.15", VERSION_FILE.read_text(encoding="utf-8").strip())


if __name__ == "__main__":
    unittest.main()
