"""Manually resolve upstream HEAD once and open an immutable snapshot update PR."""

import base64
import copy
import json
import os
import re
import subprocess
import sys
from urllib.parse import quote, urlencode

from dependency_channels import SHA, git, read_contract, validate_remote

PROJECT_PATH = "HeadsetControl-MacOSTray.xcodeproj/project.pbxproj"
MARKETING_VERSION = re.compile(
    r"^(?P<prefix>\s*MARKETING_VERSION\s*=\s*)"
    r"(?P<major>0|[1-9][0-9]*)\.(?P<minor>0|[1-9][0-9]*)\.(?P<patch>0|[1-9][0-9]*)"
    r"(?P<suffix>;\s*)$",
    re.MULTILINE,
)


class GitHub:
    def __init__(self, repository):
        if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
            raise ValueError("Invalid GitHub repository")
        self.repository = repository

    def call(self, path, data=None, optional=False):
        args = ["gh", "api", f"repos/{self.repository}" + ("/" + path if path else "")]
        if data is not None:
            args += ["--method", "POST", "--input", "-"]
        result = subprocess.run(args, input=json.dumps(data) if data is not None else None,
                                text=True, capture_output=True, timeout=120)
        if result.returncode:
            if optional and "HTTP 404" in result.stderr:
                return None
            raise ValueError(f"GitHub request failed for {path}: {result.stderr.strip()}")
        return json.loads(result.stdout)


def resolve_head(repository):
    output = git(".", "ls-remote", repository, "HEAD").stdout.split()
    if len(output) != 2 or output[1] != "HEAD" or not SHA.fullmatch(output[0]):
        raise ValueError("Upstream HEAD did not resolve to one full commit SHA")
    return output[0]


def snapshot_content(contents, revision):
    if not isinstance(revision, str) or not SHA.fullmatch(revision):
        raise ValueError("Snapshot updates require a full commit SHA")
    current = read_contract(contents)
    expected = copy.deepcopy(current)
    expected["headsetcontrol"].update(revision=revision, channel="snapshot")
    # Preserve the contract's existing layout and every unrelated field/byte.
    def replace_object(match):
        result = match.group(0)
        for key, value in (("revision", revision), ("channel", "snapshot")):
            result, count = re.subn(rf'("{key}"\s*:\s*")[^"]*(")',
                                    lambda item: item[1] + value + item[2], result)
            if count != 1:
                raise ValueError(f"Cannot uniquely update headsetcontrol.{key}")
        return result
    updated, count = re.subn(r'"headsetcontrol"\s*:\s*\{[^{}]*\}', replace_object, contents)
    if count != 1 or read_contract(updated) != expected:
        raise ValueError("Snapshot update would change more than revision and channel")
    return updated


def bump_marketing_version(contents):
    matches = list(MARKETING_VERSION.finditer(contents))
    versions = {(match["major"], match["minor"], match["patch"]) for match in matches}
    if len(matches) != 2 or len(versions) != 1:
        raise ValueError("Project must contain exactly two identical major.minor.patch MARKETING_VERSION values")
    major, minor, patch = matches[0]["major"], matches[0]["minor"], matches[0]["patch"]
    old_version = f"{major}.{minor}.{patch}"
    new_version = f"{major}.{minor}.{int(patch) + 1}"
    updated = MARKETING_VERSION.sub(
        lambda match: match["prefix"] + new_version + match["suffix"], contents
    )
    return updated, old_version, new_version


def update_snapshot(api, resolve=resolve_head, validate=validate_remote):
    repo = api.call("")
    default_branch = repo["default_branch"]
    base_ref = api.call("git/ref/heads/" + quote(default_branch, safe=""))
    base_sha = base_ref["object"]["sha"]
    if not SHA.fullmatch(base_sha):
        raise ValueError("Invalid default branch commit")
    file = api.call("contents/build-contract.json?" + urlencode({"ref": base_sha}))
    contents = base64.b64decode(file["content"]).decode()
    current = read_contract(contents)
    old = current["headsetcontrol"]
    revision = resolve(old["repository"])
    if not isinstance(revision, str) or not SHA.fullmatch(revision):
        raise ValueError("Upstream HEAD did not resolve to a full commit SHA")
    if old["revision"] == revision and old["channel"] == "snapshot":
        return "Already pinned to this snapshot; no update needed"
    project_file = api.call("contents/" + PROJECT_PATH + "?" + urlencode({"ref": base_sha}))
    project_contents = base64.b64decode(project_file["content"]).decode()
    updated_project, old_app_version, new_app_version = bump_marketing_version(project_contents)
    branch = f"codex/headsetcontrol-snapshot-{revision}-v{new_app_version}"
    query = urlencode({"state": "open", "head": api.repository.split('/')[0] + ":" + branch,
                       "per_page": 100})
    prs = api.call("pulls?" + query)
    if prs:
        if len(prs) != 1 or prs[0]["base"]["ref"] != default_branch:
            raise ValueError("Ambiguous existing snapshot PR; inspect it before retrying")
        return "Existing snapshot PR: " + prs[0]["html_url"]
    updated = snapshot_content(contents, revision)
    validate(read_contract(updated), current)
    base = api.call("git/commits/" + base_sha)
    contract_blob = api.call("git/blobs", {
        "content": base64.b64encode(updated.encode()).decode(), "encoding": "base64"
    })
    project_blob = api.call("git/blobs", {
        "content": base64.b64encode(updated_project.encode()).decode(), "encoding": "base64"
    })
    tree = api.call("git/trees", {"base_tree": base["tree"]["sha"], "tree": [
        {"path": "build-contract.json", "mode": "100644", "type": "blob", "sha": contract_blob["sha"]},
        {"path": PROJECT_PATH, "mode": "100644", "type": "blob", "sha": project_blob["sha"]},
    ]})
    existing = api.call("git/ref/heads/" + quote(branch, safe=""), optional=True)
    if existing:
        commit = api.call("git/commits/" + existing["object"]["sha"])
        if commit["tree"]["sha"] != tree["sha"] or [p["sha"] for p in commit["parents"]] != [base_sha]:
            raise ValueError("Existing snapshot branch has different content or base; never overwrite it")
    else:
        commit = api.call("git/commits", {"message": "chore(deps): select HeadsetControl snapshot " + revision[:12],
                                        "tree": tree["sha"], "parents": [base_sha]})
        api.call("git/refs", {"ref": "refs/heads/" + branch, "sha": commit["sha"]})
    body = f"""Selects an explicitly resolved HeadsetControl snapshot.

- Baseline official release version: `{old['version']}`
- Previous revision: `{old['revision']}`
- New snapshot revision: `{revision}`
- Previous channel: `{old['channel']}`
- New channel: `snapshot`
- Application version: `{old_app_version}` → `{new_app_version}`

The build remains SHA-pinned. HEAD was resolved once for this manual request;
CI and release builds consume the recorded SHA and never follow floating HEAD.
Review the normal CI and Codex results before merging. If GitHub shows an
`Approve workflows to run` banner, a maintainer must approve those CI runs.
Renovate can return this dependency to an official release only after CI proves
that the release contains this selected snapshot in its actual Git ancestry.
"""
    pr = api.call("pulls", {"title": "chore(deps): select HeadsetControl snapshot " + revision[:12],
                            "head": branch, "base": default_branch, "body": body, "draft": False})
    return "Created snapshot PR: " + pr["html_url"]


if __name__ == "__main__":
    try:
        print(update_snapshot(GitHub(os.environ["GITHUB_REPOSITORY"])))
    except (ValueError, KeyError, OSError, subprocess.SubprocessError) as error:
        sys.exit(f"Snapshot update failed: {error}")
