"""Validate pinned HeadsetControl channels and transitions using actual Git history."""

import argparse
import copy
import json
import os
import re
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SHA = re.compile(r"[0-9a-f]{40}")
VERSION = re.compile(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)")
REPOSITORY = re.compile(r"https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\.git")


def git(directory, *args, check=True):
    return subprocess.run(["git", "-C", str(directory), *map(str, args)], check=check,
                          text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120)


def validate_headsetcontrol(dependency):
    if not isinstance(dependency, dict):
        raise ValueError("Missing headsetcontrol contract")
    if dependency.get("channel") not in ("release", "snapshot"):
        raise ValueError("headsetcontrol.channel must be explicitly release or snapshot")
    if not isinstance(dependency.get("revision"), str) or not SHA.fullmatch(dependency["revision"]):
        raise ValueError("headsetcontrol.revision must be a full lowercase 40-character commit SHA")
    if not isinstance(dependency.get("version"), str) or not VERSION.fullmatch(dependency["version"]):
        raise ValueError("headsetcontrol.version must identify an official major.minor.patch baseline")
    if not isinstance(dependency.get("repository"), str) or not REPOSITORY.fullmatch(dependency["repository"]):
        raise ValueError("headsetcontrol.repository must be an HTTPS GitHub repository URL ending in .git")
    return dependency


def validate_contract(contract):
    if not isinstance(contract, dict):
        raise ValueError("Missing build contract")
    return validate_headsetcontrol(contract.get("headsetcontrol"))


def read_contract(contents):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError(f"Duplicate build contract key: {key}")
            result[key] = value
        return result
    result = json.loads(contents, object_pairs_hook=unique)
    validate_contract(result)
    return result


def verify_release_tag(directory, dependency, offline=False):
    """Fetch only the declared baseline tag; never use it to select build sources."""
    validate_headsetcontrol(dependency)
    tag = "refs/tags/" + dependency["version"]
    if not offline:
        git(directory, "fetch", "--no-tags", "--depth=1", dependency["repository"], f"+{tag}:{tag}")
    result = git(directory, "rev-parse", "--verify", tag + "^{commit}", check=False)
    if result.returncode or not SHA.fullmatch(result.stdout.strip()):
        raise ValueError(f"Cannot verify official HeadsetControl tag {dependency['version']}; "
                         "offline builds require a previously fetched tag")
    revision = result.stdout.strip()
    if dependency["channel"] == "release" and revision != dependency["revision"]:
        raise ValueError(f"HeadsetControl release {dependency['version']} resolves to {revision}, "
                         f"not the pinned revision {dependency['revision']}")
    return revision


def transition(base, proposed):
    current = validate_contract(proposed)
    # One-time migration: the pre-channel contract may only gain channel=release.
    # Missing channel is never accepted in a build or proposed contract.
    if isinstance(base.get("headsetcontrol"), dict) and "channel" not in base["headsetcontrol"]:
        migrated = copy.deepcopy(base)
        migrated["headsetcontrol"]["channel"] = "release"
        if proposed != migrated:
            raise ValueError("Base contract has no channel; first add only channel=release")
        return False
    previous = validate_contract(base)
    if previous["repository"] != current["repository"]:
        raise ValueError("A dependency channel transition cannot change the HeadsetControl repository")
    if current["channel"] == "snapshot" and current["version"] != previous["version"]:
        raise ValueError("Selecting a snapshot must preserve the official baseline version")
    if current["channel"] == "release":
        if tuple(map(int, current["version"].split('.'))) < tuple(map(int, previous["version"].split('.'))):
            raise ValueError("A release transition must not downgrade the official baseline version")
        if (previous["channel"] == "release" and current["version"] == previous["version"]
                and current["revision"] != previous["revision"]):
            raise ValueError("Do not change the pinned revision of the same official release")
    return previous["channel"] == "snapshot" and current["channel"] == "release"


def validate_snapshot_pr(base, proposed, event, repository):
    """Changed snapshots must come from the manual updater's same-repository bot PR."""
    current = validate_contract(proposed)
    previous = base.get("headsetcontrol", {})
    if current["channel"] != "snapshot" or all(previous.get(key) == current[key] for key in ("revision", "channel")):
        return
    expected = copy.deepcopy(base)
    expected["headsetcontrol"].update(revision=current["revision"], channel="snapshot")
    pr = event.get("pull_request", {})
    head = pr.get("head", {})
    if (proposed != expected or pr.get("user", {}).get("login") != "github-actions[bot]"
            or not re.fullmatch(r"codex/headsetcontrol-snapshot-" + current["revision"]
                                + r"-v" + VERSION.pattern, head.get("ref", ""))
            or head.get("repo", {}).get("full_name") != repository or not repository):
        raise ValueError("Select snapshots through the manual Update HeadsetControl snapshot workflow; "
                         "its PR may change only revision and channel")


def require_ancestor(repository, snapshot, release, directory):
    """Deepen only the two exact tips until ancestry is proven or history is complete."""
    if not SHA.fullmatch(snapshot) or not SHA.fullmatch(release):
        raise ValueError("Ancestry checks require two full commit SHAs")
    git(directory, "init", "--bare")
    git(directory, "fetch", "--no-tags", "--filter=blob:none", "--depth=1", repository,
        f"{snapshot}:refs/heads/snapshot", f"{release}:refs/heads/release")
    depth = 32
    while True:
        result = git(directory, "merge-base", "--is-ancestor", snapshot, release, check=False)
        if result.returncode == 0:
            return
        if result.returncode != 1:
            raise ValueError(f"Cannot establish HeadsetControl ancestry: {result.stderr.strip()}")
        shallow_path = Path(directory) / "shallow"
        shallow = set(shallow_path.read_text().splitlines()) if shallow_path.exists() else set()
        reachable = set(git(directory, "rev-list", release).stdout.splitlines())
        if not shallow.intersection(reachable):
            raise ValueError(f"Official HeadsetControl release {release} does not yet contain "
                             f"selected snapshot {snapshot}; keep this PR failing until it does")
        before = shallow.copy()
        git(directory, "fetch", "--no-tags", "--filter=blob:none", f"--deepen={depth}", repository,
            release, snapshot)
        after = set(shallow_path.read_text().splitlines()) if shallow_path.exists() else set()
        if before == after:
            raise ValueError("HeadsetControl ancestry fetch made no progress; cannot safely return to release")
        depth *= 4


def validate_remote(contract, base=None):
    dependency = validate_contract(contract)
    needs_ancestry = transition(base, contract) if base is not None else False
    with tempfile.TemporaryDirectory(prefix="headset-channel-") as directory:
        git(directory, "init", "--bare")
        # Verify the pinned object is a commit, even for a snapshot baseline.
        git(directory, "fetch", "--no-tags", "--depth=1", dependency["repository"], dependency["revision"])
        actual = git(directory, "rev-parse", "FETCH_HEAD^{commit}").stdout.strip()
        if actual != dependency["revision"]:
            raise ValueError("The pinned HeadsetControl object is not a commit")
        verify_release_tag(directory, dependency)
    if needs_ancestry:
        with tempfile.TemporaryDirectory(prefix="headset-ancestry-") as directory:
            require_ancestor(dependency["repository"], base["headsetcontrol"]["revision"],
                             dependency["revision"], directory)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--contract", type=Path, default=ROOT / "build-contract.json")
    parser.add_argument("--base-branch", default="")
    args = parser.parse_args()
    try:
        contract = read_contract(args.contract.read_text())
        base = None
        if args.base_branch:
            ref = "refs/heads/" + args.base_branch
            git(ROOT, "check-ref-format", ref)
            git(ROOT, "fetch", "--no-tags", "--depth=1", "origin", ref)
            base_revision = git(ROOT, "rev-parse", "FETCH_HEAD").stdout.strip()
            base = json.loads(git(ROOT, "show", f"{base_revision}:build-contract.json").stdout)
            event_path = os.environ.get("GITHUB_EVENT_PATH")
            event = json.loads(Path(event_path).read_text()) if event_path else {}
            validate_snapshot_pr(base, contract, event, os.environ.get("GITHUB_REPOSITORY"))
        validate_remote(contract, base)
        if args.base_branch:
            current = git(ROOT, "ls-remote", "origin", ref).stdout.split()
            if len(current) != 2 or current[0] != base_revision:
                raise ValueError("Base branch advanced during dependency validation; rerun CI")
        print(f"Verified pinned HeadsetControl {contract['headsetcontrol']['channel']} contract")
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        parser.exit(1, f"Dependency channel validation failed: {error}\n")


if __name__ == "__main__":
    main()
