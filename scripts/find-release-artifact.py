#!/usr/bin/env python3
"""Find a unique, unexpired artifact from this workflow run, including retries."""
import argparse
import json
import os
from pathlib import Path
import subprocess


def select(artifacts, name):
    matches = [artifact for artifact in artifacts if artifact.get("name") == name]
    if len(matches) > 1:
        raise ValueError("More than one original release artifact matches")
    if not matches:
        return None
    artifact = matches[0]
    if artifact.get("expired") is not False or not isinstance(artifact.get("id"), int):
        raise ValueError("The original release artifact has expired; recover its exact bytes")
    return artifact["id"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("name")
    args = parser.parse_args()
    repo, run = os.environ["GITHUB_REPOSITORY"], os.environ["GITHUB_RUN_ID"]
    pages = json.loads(subprocess.check_output([
        "gh", "api", "--paginate", "--slurp",
        f"repos/{repo}/actions/runs/{run}/artifacts?per_page=100",
    ], text=True))
    artifact_id = select([artifact for page in pages for artifact in page["artifacts"]], args.name)
    with Path(os.environ["GITHUB_OUTPUT"]).open("a") as output:
        output.write(f"exists={str(artifact_id is not None).lower()}\n")
        if artifact_id is not None:
            output.write(f"id={artifact_id}\n")


if __name__ == "__main__":
    main()
