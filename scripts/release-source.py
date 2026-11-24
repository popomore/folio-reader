#!/usr/bin/env python3
"""Require successful push CI from the official stable release branch."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess


def gh(path):
    return json.loads(subprocess.check_output(["gh", "api", path], text=True))


def validate(run, workflow_id, repository, tip, selected_branch=None, retry=False):
    sha = run.get("head_sha", "")
    if (run.get("workflow_id") != workflow_id
            or run.get("path") != ".github/workflows/ci.yml"
            or run.get("event") != "push" or run.get("status") != "completed"
            or run.get("conclusion") != "success" or run.get("head_branch") != "release"
            or run.get("repository", {}).get("full_name") != repository
            or run.get("head_repository", {}).get("full_name") != repository
            or not re.fullmatch("[0-9a-f]{40}", sha)):
        raise ValueError("Release requires successful push CI from the official release branch")
    if sha != tip and not retry:
        raise ValueError("The tested SHA is no longer the release branch tip")
    if selected_branch is not None and selected_branch != "release":
        raise ValueError("Dispatch the workflow on the tested release branch")
    return sha


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ci_run_id")
    parser.add_argument("--dispatch", action="store_true")
    args = parser.parse_args()
    if not re.fullmatch(r"[1-9]\d*", args.ci_run_id):
        parser.error("A numeric CI run ID is required")
    repo = os.environ["GITHUB_REPOSITORY"]
    run = gh(f"repos/{repo}/actions/runs/{args.ci_run_id}")
    if str(run.get("id")) != args.ci_run_id:
        raise ValueError("CI run ID mismatch")
    workflow = gh(f"repos/{repo}/actions/workflows/ci.yml")
    tip = gh(f"repos/{repo}/git/ref/heads/release")["object"]["sha"]
    sha = validate(run, workflow["id"], repo, tip,
                   selected_branch=None if args.dispatch else os.environ["GITHUB_REF_NAME"],
                   retry=not args.dispatch and int(os.environ.get("GITHUB_RUN_ATTEMPT", "1")) > 1)
    if args.dispatch:
        subprocess.run(["gh", "workflow", "run", "release-stable.yml", "--repo", repo,
                        "--ref", "release", "--field", "ci-run-id=" + args.ci_run_id], check=True)
    else:
        if os.environ["GITHUB_REF"] != "refs/heads/release":
            raise ValueError("A release branch dispatch is required")
        with Path(os.environ["GITHUB_OUTPUT"]).open("a") as output:
            output.write(f"source-sha={sha}\nci-run-id={args.ci_run_id}\n")


if __name__ == "__main__":
    main()
