import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import dependency_channels as channels
import native_contract as native
from test_release_artifact import PLIST, provenance_fixture


def contract(channel="release", revision="a" * 40, version="4.1.0"):
    result = copy.deepcopy(native.CONTRACT)
    result["headsetcontrol"].update(channel=channel, revision=revision, version=version)
    return result


class ChannelContractTests(unittest.TestCase):
    def test_valid_channels_and_invalid_metadata(self):
        for channel in ("release", "snapshot"):
            value = contract(channel)
            self.assertEqual(channels.read_contract(json.dumps(value)), value)
        for field, invalid in (("channel", None), ("channel", "HEAD"), ("channel", ""),
                               ("revision", "HEAD"), ("revision", "master"), ("revision", "4.1.0"),
                               ("revision", "a" * 39), ("revision", "a" * 41), ("revision", "g" * 40),
                               ("version", "HEAD"), ("version", "4.2.0-rc.1"),
                               ("repository", "file:///untrusted")):
            value = contract()
            if invalid is None:
                del value["headsetcontrol"][field]
            else:
                value["headsetcontrol"][field] = invalid
            with self.subTest(field=field, invalid=invalid), self.assertRaises(ValueError):
                channels.validate_contract(value)
        with self.assertRaisesRegex(ValueError, "Duplicate"):
            channels.read_contract('{"headsetcontrol": {}, "headsetcontrol": {}}')

    def test_all_four_transitions(self):
        release = contract()
        snapshot = contract("snapshot", "b" * 40)
        for base, proposed, ancestry in (
            (release, contract("release", "c" * 40, "4.2.0"), False),
            (release, snapshot, False),
            (snapshot, contract("snapshot", "d" * 40), False),
            (snapshot, contract("release", "e" * 40, "4.2.0"), True),
        ):
            with self.subTest(base=base, proposed=proposed):
                self.assertEqual(channels.transition(base, proposed), ancestry)
        for base in (release, snapshot):
            with self.assertRaisesRegex(ValueError, "baseline"):
                channels.transition(base, contract("snapshot", "d" * 40, "4.2.0"))
            with self.assertRaisesRegex(ValueError, "downgrade"):
                channels.transition(base, contract("release", "d" * 40, "4.0.0"))
        with self.assertRaisesRegex(ValueError, "same official release"):
            channels.transition(release, contract("release", "d" * 40))
        other_repo = contract("release", "e" * 40, "4.2.0")
        other_repo["headsetcontrol"]["repository"] = "https://github.com/example/fork.git"
        with self.assertRaisesRegex(ValueError, "repository"):
            channels.transition(snapshot, other_repo)

    def test_initial_channel_migration_does_not_allow_dependency_changes(self):
        proposed = contract()
        base = copy.deepcopy(proposed)
        del base["headsetcontrol"]["channel"]
        self.assertFalse(channels.transition(base, proposed))
        with self.assertRaises(ValueError):
            channels.validate_contract(base)
        for change in ({"revision": "b" * 40}, {"channel": "snapshot"}, {"version": "4.2.0"}):
            altered = copy.deepcopy(proposed)
            altered["headsetcontrol"].update(change)
            with self.assertRaisesRegex(ValueError, "first add only"):
                channels.transition(base, altered)

    def test_only_manual_workflow_prs_can_select_a_snapshot(self):
        selected = contract("snapshot", "b" * 40)
        event = {"pull_request": {"user": {"login": "github-actions[bot]"}, "head": {
            "ref": "codex/headsetcontrol-snapshot-" + "b" * 40 + "-v3.1.1",
            "repo": {"full_name": "owner/app"}}}}
        for previous in (contract(), contract("snapshot", "c" * 40)):
            channels.validate_snapshot_pr(previous, selected, event, "owner/app")
            for field, value in (("user", {"login": "someone"}), ("head", {"ref": "another-branch"})):
                altered = copy.deepcopy(event)
                altered["pull_request"][field] = value
                with self.assertRaisesRegex(ValueError, "manual Update HeadsetControl"):
                    channels.validate_snapshot_pr(previous, selected, altered, "owner/app")
            with self.assertRaises(ValueError):
                channels.validate_snapshot_pr(previous, selected, event, "different/fork")
            altered = copy.deepcopy(selected)
            altered["macos"] = "15.0"
            with self.assertRaisesRegex(ValueError, "only revision and channel"):
                channels.validate_snapshot_pr(previous, altered, event, "owner/app")
        # Feature PRs while a snapshot is already selected need no bot identity.
        channels.validate_snapshot_pr(selected, selected, {}, "owner/app")
        channels.validate_snapshot_pr(selected, contract("release", "c" * 40, "4.2.0"), {}, "owner/app")

    def test_provenance_records_and_compares_both_channels(self):
        for channel in ("release", "snapshot"):
            selected = contract(channel)
            with patch.object(native, "CONTRACT", selected):
                provenance = provenance_fixture()
                provenance["headsetcontrol"] = copy.deepcopy(selected["headsetcontrol"])
                native.validate_provenance(provenance, PLIST)
                other = copy.deepcopy(provenance)
                other["headsetcontrol"]["channel"] = "snapshot" if channel == "release" else "release"
                with self.assertRaisesRegex(ValueError, "headsetcontrol"):
                    native.validate_provenance(other, PLIST)
                with self.assertRaisesRegex(ValueError, "headsetcontrol"):
                    native.compare_provenance(provenance, other)
                del other["headsetcontrol"]["channel"]
                with self.assertRaisesRegex(ValueError, "channel"):
                    native.validate_provenance(other, PLIST)


class GitChannelTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="headset upstream fixtures ")
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.upstream = Path(cls.temporary.name)
        cls.actual_git = staticmethod(channels.git)
        cls.actual_git(cls.upstream, "init", "-b", "main")
        cls.actual_git(cls.upstream, "config", "user.email", "fixture@example.invalid")
        cls.actual_git(cls.upstream, "config", "user.name", "Fixture")
        cls.actual_git(cls.upstream, "config", "commit.gpgsign", "false")
        cls.actual_git(cls.upstream, "config", "tag.gpgsign", "false")
        cls.baseline = cls.commit("baseline")
        cls.actual_git(cls.upstream, "tag", "4.1.0")
        cls.snapshot = cls.commit("snapshot")
        # More than the first deepening increment: never reject a shallow false negative.
        for index in range(36):
            cls.commit(f"later-{index}")
        cls.release = cls.commit("containing release")
        cls.actual_git(cls.upstream, "tag", "-a", "4.2.0", "-m", "Annotated release")
        cls.tag_object = cls.actual_git(cls.upstream, "rev-parse", "4.2.0").stdout.strip()
        cls.actual_git(cls.upstream, "checkout", "-b", "divergent", cls.baseline)
        cls.divergent = cls.commit("release without snapshot")
        cls.actual_git(cls.upstream, "tag", "4.3.0")
        cls.repository = cls.upstream.as_uri()

    @classmethod
    def commit(cls, message):
        (cls.upstream / "source.c").write_text(message)
        cls.actual_git(cls.upstream, "add", "source.c")
        cls.actual_git(cls.upstream, "commit", "-m", message)
        return cls.actual_git(cls.upstream, "rev-parse", "HEAD").stdout.strip()

    def redirected_git(self, directory, *args, **kwargs):
        return self.actual_git(directory, *[self.repository if arg == native.CONTRACT["headsetcontrol"]["repository"]
                                           else arg for arg in args], **kwargs)

    def test_release_tags_resolve_to_commits_including_annotated_tags(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(channels, "git", self.redirected_git):
            self.actual_git(directory, "init", "--bare")
            for version, revision in (("4.1.0", self.baseline), ("4.2.0", self.release)):
                dep = contract("release", revision, version)["headsetcontrol"]
                self.assertEqual(channels.verify_release_tag(directory, dep), revision)
                self.assertEqual(channels.verify_release_tag(directory, dep, offline=True), revision)
            self.assertNotEqual(self.tag_object, self.release)
            wrong = contract("release", self.tag_object, "4.2.0")["headsetcontrol"]
            with self.assertRaisesRegex(ValueError, "not the pinned revision"):
                channels.verify_release_tag(directory, wrong)
            unknown = contract("snapshot", self.snapshot, "99.0.0")["headsetcontrol"]
            with self.assertRaisesRegex(ValueError, "previously fetched tag"):
                channels.verify_release_tag(directory, unknown, offline=True)

    def test_full_release_validation_and_mismatch(self):
        with patch.object(channels, "git", self.redirected_git):
            channels.validate_remote(contract("release", self.release, "4.2.0"))
            channels.validate_remote(contract("snapshot", self.snapshot))
            with self.assertRaisesRegex(ValueError, "not the pinned revision"):
                channels.validate_remote(contract("release", self.snapshot))
            with self.assertRaisesRegex(ValueError, "not a commit"):
                channels.validate_remote(contract("snapshot", self.tag_object))

    def test_snapshot_to_release_uses_real_ancestry(self):
        with patch.object(channels, "git", self.redirected_git):
            selected = contract("snapshot", self.snapshot)
            channels.validate_remote(contract("release", self.release, "4.2.0"), selected)
            with self.assertRaisesRegex(ValueError, "does not yet contain selected snapshot"):
                channels.validate_remote(contract("release", self.divergent, "4.3.0"), selected)

    def test_equal_revision_is_allowed_and_shallow_history_is_deepened(self):
        with tempfile.TemporaryDirectory() as directory:
            channels.require_ancestor(self.repository, self.release, self.release, directory)
        with tempfile.TemporaryDirectory() as directory, patch.object(channels, "git", wraps=self.actual_git) as git:
            channels.require_ancestor(self.repository, self.snapshot, self.release, directory)
            fetches = [call.args for call in git.call_args_list if "fetch" in call.args]
            self.assertTrue(any("--deepen=32" in call for call in fetches))
            self.assertTrue(any("--deepen=128" in call for call in fetches))
            self.assertFalse(any("--unshallow" in call for call in fetches))


if __name__ == "__main__":
    unittest.main()
