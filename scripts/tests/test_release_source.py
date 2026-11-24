import copy
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).resolve().parents[1] / filename)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


source = module("release_source", "release-source.py")
artifacts = module("release_artifacts", "find-release-artifact.py")


class SourceTests(unittest.TestCase):
    def setUp(self):
        self.sha = "a" * 40
        self.repo = "example/folio"
        self.run = {"id": 41, "workflow_id": 7, "path": ".github/workflows/ci.yml", "event": "push",
                    "status": "completed", "conclusion": "success", "head_branch": "release", "head_sha": self.sha,
                    "repository": {"full_name": self.repo}, "head_repository": {"full_name": self.repo}}

    def test_exact_successful_push_is_admitted(self):
        self.assertEqual(source.validate(self.run, 7, self.repo, self.sha, "release"), self.sha)

    def test_spoofed_workflow_branch_repository_or_result_is_rejected(self):
        for key, value in {"workflow_id": 8, "path": ".github/workflows/other.yml", "event": "pull_request",
                           "status": "in_progress", "conclusion": "failure", "head_branch": "main", "head_sha": "bad",
                           "repository": {"full_name": "fork/folio"}, "head_repository": {"full_name": "fork/folio"}}.items():
            with self.subTest(key=key):
                run = copy.deepcopy(self.run)
                run[key] = value
                with self.assertRaises(ValueError):
                    source.validate(run, 7, self.repo, self.sha)
        with self.assertRaisesRegex(ValueError, "Dispatch"):
            source.validate(self.run, 7, self.repo, self.sha, "main")

    def test_stale_source_requires_retry_and_still_requires_success(self):
        with self.assertRaisesRegex(ValueError, "branch tip"):
            source.validate(self.run, 7, self.repo, "b" * 40)
        self.assertEqual(source.validate(self.run, 7, self.repo, "b" * 40, retry=True), self.sha)
        self.run["conclusion"] = "failure"
        with self.assertRaises(ValueError):
            source.validate(self.run, 7, self.repo, "b" * 40, retry=True)

    def test_dispatch_uses_the_verified_run_and_release_ref(self):
        with patch.dict(source.os.environ, {"GITHUB_REPOSITORY": self.repo}), \
                patch("sys.argv", ["release-source.py", "41", "--dispatch"]), \
                patch.object(source, "gh", side_effect=[self.run, {"id": 7}, {"object": {"sha": self.sha}}]), \
                patch.object(source.subprocess, "run") as dispatch:
            source.main()
        dispatch.assert_called_once_with(["gh", "workflow", "run", "release-stable.yml", "--repo", self.repo,
                                          "--ref", "release", "--field", "ci-run-id=41"], check=True)

    def test_source_output_and_tag_dispatch_rejection(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "outputs"
            env = {"GITHUB_REPOSITORY": self.repo, "GITHUB_REF_NAME": "release", "GITHUB_REF": "refs/heads/release",
                   "GITHUB_OUTPUT": str(output), "GITHUB_RUN_ATTEMPT": "1"}
            for ref in ["refs/tags/release", "refs/heads/release"]:
                with patch.dict(source.os.environ, {**env, "GITHUB_REF": ref}), \
                        patch("sys.argv", ["release-source.py", "41"]), \
                        patch.object(source, "gh", side_effect=[self.run, {"id": 7}, {"object": {"sha": self.sha}}]):
                    if ref.startswith("refs/tags/"):
                        with self.assertRaises(ValueError):
                            source.main()
                        self.assertFalse(output.exists())
                    else:
                        source.main()
                        self.assertEqual(output.read_text(), f"source-sha={self.sha}\nci-run-id=41\n")


class ArtifactTests(unittest.TestCase):
    def test_absent_or_exact_original_artifact(self):
        self.assertIsNone(artifacts.select([], "plan"))
        self.assertEqual(artifacts.select([{"id": 42, "name": "plan", "expired": False}], "plan"), 42)
        self.assertIsNone(artifacts.select([{"id": 42, "name": "other", "expired": False}], "plan"))

    def test_expired_ambiguous_and_invalid_artifacts_fail_closed(self):
        valid = {"id": 42, "name": "plan", "expired": False}
        for values in [[valid, valid], [{**valid, "expired": True}], [{**valid, "id": "42"}]]:
            with self.assertRaises(ValueError):
                artifacts.select(values, "plan")


if __name__ == "__main__":
    unittest.main()
