import base64
import copy
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import update_headsetcontrol as updater
from test_dependency_channels import contract


class FakeGitHub:
    repository = "owner/app"

    def __init__(self, current):
        self.contents = json.dumps(current, indent=2) + "\n"
        self.base = "1" * 40
        self.branch = None
        self.commits = {self.base: {"tree": {"sha": "2" * 40}, "parents": []}}
        self.prs = []
        self.mutations = []
        self.blob = None
        self.fail_pr = False

    def call(self, path, data=None, optional=False):
        if data is not None:
            self.mutations.append((path, data))
        if path == "":
            return {"default_branch": "main"}
        if path == "git/ref/heads/main":
            return {"object": {"sha": self.base}}
        if path.startswith("contents/build-contract.json?"):
            return {"content": base64.b64encode(self.contents.encode()).decode()}
        if path.startswith("pulls?"):
            return copy.deepcopy(self.prs)
        if path.startswith("git/commits/"):
            return self.commits[path.rsplit('/', 1)[1]]
        if path == "git/blobs":
            self.blob = base64.b64decode(data["content"]).decode()
            return {"sha": hashlib.sha1(self.blob.encode()).hexdigest()}
        if path == "git/trees":
            return {"sha": data["tree"][0]["sha"]}
        if path.startswith("git/ref/heads/"):
            assert optional
            return {"object": {"sha": self.branch}} if self.branch else None
        if path == "git/commits":
            sha = "3" * 40
            self.commits[sha] = {"tree": {"sha": data["tree"]},
                                 "parents": [{"sha": p} for p in data["parents"]]}
            return {"sha": sha}
        if path == "git/refs":
            assert data["ref"].startswith("refs/heads/codex/headsetcontrol-snapshot-")
            self.branch = data["sha"]
            return {}
        if path == "pulls":
            if self.fail_pr:
                raise ValueError("interrupted before PR creation")
            pr = {"html_url": "https://github.com/owner/app/pull/1", "base": {"ref": "main"}}
            self.prs.append(pr)
            return pr
        raise AssertionError(path)


class SnapshotUpdateTests(unittest.TestCase):
    def test_release_and_snapshot_updates_change_only_two_fields(self):
        for channel in ("release", "snapshot"):
            before = contract(channel)
            api = FakeGitHub(before)
            def resolve(repository):
                self.assertEqual(repository, before["headsetcontrol"]["repository"])
                return "b" * 40
            with patch.object(updater, "validate_remote") as validate:
                # Pass the validation seam explicitly; production defaults always validate Git metadata.
                result = updater.update_snapshot(api, resolve, validate)
            self.assertIn("Created snapshot PR", result)
            expected = copy.deepcopy(before)
            expected["headsetcontrol"].update(channel="snapshot", revision="b" * 40)
            self.assertEqual(json.loads(api.blob), expected)
            validate.assert_called_once_with(expected, before)
            prs = [data for path, data in api.mutations if path == "pulls"]
            self.assertEqual(len(prs), 1)
            self.assertEqual(prs[0]["head"], "codex/headsetcontrol-snapshot-" + "b" * 40)
            for text in ("4.1.0", "a" * 40, "b" * 40, f"Previous channel: `{channel}`", "New channel: `snapshot`", "SHA-pinned"):
                self.assertIn(text, prs[0]["body"])
            trees = [data for path, data in api.mutations if path == "git/trees"]
            self.assertEqual([item["path"] for item in trees[0]["tree"]], ["build-contract.json"])

    def test_noop_and_duplicate_pr_have_no_mutations(self):
        api = FakeGitHub(contract("snapshot", "b" * 40))
        self.assertIn("no update needed", updater.update_snapshot(api, lambda repo: "b" * 40))
        self.assertEqual(api.mutations, [])
        api = FakeGitHub(contract())
        api.prs = [{"base": {"ref": "main"}, "html_url": "https://github.com/owner/app/pull/1"}]
        self.assertIn("Existing snapshot PR", updater.update_snapshot(api, lambda repo: "b" * 40))
        self.assertEqual(api.mutations, [])

    def test_interrupted_branch_creation_can_resume_without_replacing_branch(self):
        api = FakeGitHub(contract())
        api.fail_pr = True
        validate = lambda *args: None
        with self.assertRaisesRegex(ValueError, "interrupted"):
            updater.update_snapshot(api, lambda repo: "b" * 40, validate)
        api.fail_pr = False
        updater.update_snapshot(api, lambda repo: "b" * 40, validate)
        self.assertEqual(sum(path == "git/refs" for path, data in api.mutations), 1)
        self.assertEqual(sum(path == "git/commits" for path, data in api.mutations), 1)
        previous = len(api.mutations)
        updater.update_snapshot(api, lambda repo: "b" * 40, validate)
        self.assertEqual(len(api.mutations), previous)

    def test_conflicting_branch_and_failed_validation_never_create_pr(self):
        api = FakeGitHub(contract())
        api.branch = api.base
        with self.assertRaisesRegex(ValueError, "never overwrite"):
            updater.update_snapshot(api, lambda repo: "b" * 40, lambda *args: None)
        self.assertFalse(any(path in ("pulls", "git/refs", "git/commits") for path, data in api.mutations))
        api = FakeGitHub(contract())
        def invalid(*args):
            raise ValueError("invalid metadata")
        with self.assertRaisesRegex(ValueError, "invalid metadata"):
            updater.update_snapshot(api, lambda repo: "b" * 40, invalid)
        self.assertEqual(api.mutations, [])

    def test_malformed_head_cannot_be_stored_and_contract_format_is_preserved(self):
        for value in ("HEAD", "main", "4.1.0", "a" * 39, "g" * 40):
            api = FakeGitHub(contract())
            with self.assertRaisesRegex(ValueError, "full commit SHA"):
                updater.update_snapshot(api, lambda repo: value)
            self.assertEqual(api.mutations, [])
        contents = json.dumps(contract(), indent=4) + "\n"
        expected = contents.replace('"revision": "' + 'a' * 40 + '"', '"revision": "' + 'b' * 40 + '"').replace('"channel": "release"', '"channel": "snapshot"')
        self.assertEqual(updater.snapshot_content(contents, "b" * 40), expected)
        with patch.object(updater, "git", return_value=subprocess.CompletedProcess([], 0, "b" * 40 + "\tHEAD\n", "")):
            self.assertEqual(updater.resolve_head("https://github.com/Sapd/HeadsetControl.git"), "b" * 40)
        for output in ("HEAD\tHEAD", "b" * 40 + "\trefs/heads/main", "b" * 40 + "\tHEAD\n" + "c" * 40 + "\tHEAD"):
            with patch.object(updater, "git", return_value=subprocess.CompletedProcess([], 0, output, "")):
                with self.assertRaises(ValueError):
                    updater.resolve_head("https://github.com/Sapd/HeadsetControl.git")


if __name__ == "__main__":
    unittest.main()
