import datetime
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class CloudProfileTests(unittest.TestCase):
    def prepare(self, grant, requested=None, mode="preview", services=None):
        template = ROOT / "apps/macos/iCloud.entitlements"
        entitlements = plistlib.loads(template.read_bytes())
        entitlements.update({
            "com.apple.application-identifier": "FIXTURETEAM.org.popomore.folio.preview",
            "com.apple.developer.icloud-container-environment": grant,
        })
        if services is not None:
            entitlements["com.apple.developer.icloud-services"] = services
        profile = {
            "TeamIdentifier": ["FIXTURETEAM"],
            "ApplicationIdentifierPrefix": ["FIXTURETEAM"],
            "ExpirationDate": datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None) + datetime.timedelta(days=1),
            "Entitlements": entitlements,
        }
        script = (ROOT / "scripts/build-macos").read_text().split("<<'CLOUD'\n", 1)[1].split("\nCLOUD", 1)[0]
        with tempfile.TemporaryDirectory(prefix="folio-profile-") as temp:
            base = Path(temp)
            source, output, info = [base / name for name in ("profile.plist", "entitlements.plist", "Info.plist")]
            source.write_bytes(plistlib.dumps(profile))
            info.write_bytes(plistlib.dumps({"FolioCloudEnvironment": "Development"}))
            env = {**os.environ, "FOLIO_ICLOUD_BUILD_MODE": mode}
            env.pop("FOLIO_ICLOUD_ENVIRONMENT", None)
            if requested is not None:
                env["FOLIO_ICLOUD_ENVIRONMENT"] = requested
            run = subprocess.run([sys.executable, "-", str(source), str(template), str(output),
                                  "org.popomore.folio.preview", "Apple Development: Fixture (FIXTURETEAM)", str(info)],
                                 input=script, text=True, capture_output=True, env=env)
            return run.returncode, run.stderr, (plistlib.loads(output.read_bytes()) if output.exists() else None), plistlib.loads(info.read_bytes())

    def assert_environment(self, grant, expected, **kwargs):
        code, error, entitlements, info = self.prepare(grant, **kwargs)
        self.assertEqual(code, 0, error)
        self.assertEqual(entitlements["com.apple.developer.icloud-container-environment"], expected)
        self.assertEqual(info["FolioCloudEnvironment"], expected)

    def test_scalar_grants_keep_the_authorized_environment(self):
        self.assert_environment("Production", "Production")
        self.assert_environment("Development", "Development")

    def test_array_grant_selects_the_build_environment(self):
        self.assert_environment(["Development", "Production"], "Development")
        self.assert_environment(["Development", "Production"], "Production", mode="release")
        self.assert_environment(["Development", "Production"], "Production", mode="preview-release")

    def test_explicit_environment_must_be_authorized(self):
        self.assert_environment(["Development", "Production"], "Production", requested="Production")
        code, _, _, _ = self.prepare("Development", requested="Production")
        self.assertNotEqual(code, 0)

    def test_single_array_grant_is_unambiguous(self):
        self.assert_environment(["Production"], "Production")

    def test_invalid_environment_grant_is_rejected(self):
        for grant in ([], ["Other"], ["Development", "Other"]):
            code, _, _, _ = self.prepare(grant)
            self.assertNotEqual(code, 0)

    def test_wildcard_services_preserve_the_requested_entitlements(self):
        for services in ("*", ["*"]):
            code, error, entitlements, _ = self.prepare("Development", services=services)
            self.assertEqual(code, 0, error)
            self.assertEqual(set(entitlements["com.apple.developer.icloud-services"]), {"CloudKit", "CloudDocuments"})
        code, _, _, _ = self.prepare("Development", services=["CloudDocuments"])
        self.assertNotEqual(code, 0)


if __name__ == "__main__":
    unittest.main()
