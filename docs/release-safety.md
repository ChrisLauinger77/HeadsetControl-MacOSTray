# Release publication and recovery

Releases use two stages in `.github/workflows/release.yml`: build once, test the
candidate, tag the exact source commit, and publish the already verified bytes.

## Stage 1: build a candidate (manual run)

Start **Release** with “Run workflow” on `main`. The run:

1. Requires `workflow_dispatch` on the default branch and a first run attempt.
2. Reads the consistent `MARKETING_VERSION` from the Xcode project (`X.Y.Z`) and
   rejects a version whose `vX.Y.Z` tag already exists.
3. Runs the release script tests, then builds and tests both architectures with
   the pinned [build contract](build-contract.md).
4. Generates one `YYMMDD.HHMM` build number (`Europe/Berlin`) and passes that exact
   value to both architecture builds.
5. Combines, ad-hoc signs and validates the universal `HeadsetControl-MacOSTray.zip`,
   including the archive gate the publisher uses (tag/version, source revision,
   both slices).
6. Retains a `release-assets` artifact for 30 days containing:
   - `HeadsetControl-MacOSTray.zip` — the release asset;
   - `SHA256SUMS` — its SHA-256;
   - `candidate.json` — repository, version, tag, source commit, run ID and attempt.
7. Writes the exact tagging commands to the job summary.

This stage has read-only repository permissions, no secrets, and never creates
releases, tags or package-repository updates. Candidate runs do not share a
concurrency group, so they never cancel each other.

## Approving and tagging

Download the complete `release-assets` artifact from the successful run and test
it. When satisfied, run the commands from the job summary, for example:

```bash
git tag -a v3.2.2 <full commit SHA from the summary> \
  -m "HeadsetControl-MacOSTray 3.2.2" \
  -m "Candidate-Run: <run ID from the summary>"

git push origin v3.2.2
```

The command tags the candidate's source commit, not the local `HEAD`.

- Push the tag before the artifact expires (30 days, subject to repository limits).
- For a different candidate, start a **new** manual run. Do not rerun a candidate
  run: reruns can replace artifacts under the same run ID and are rejected.

## Stage 2: publish the candidate (tag push)

The tag-triggered publish job builds nothing. Before any release mutation it
verifies, using the GitHub REST API:

- the tag matches the Xcode marketing version at the tagged commit;
- `refs/tags/vX.Y.Z` is an annotated tag that directly annotates the pushed commit
  and contains exactly one `Candidate-Run: <run ID>` line;
- the run belongs to this repository (also as head repository), is this same
  workflow (path and workflow ID), used `workflow_dispatch` on the default branch,
  completed with `success` on attempt 1, and built exactly the tagged commit;
- the run has exactly one unexpired, non-empty `release-assets` artifact whose
  recorded run and commit match.

It downloads that artifact by run and artifact ID and requires exactly the three
files above. `candidate.json` must match the tag, version, commit, run and
repository, and the ZIP must match its original `SHA256SUMS` entry. Checksums are
never regenerated. The ZIP is validated again (bundle identity, tag version,
embedded source revision, both architecture slices) before upload.

The publish job alone has `contents: write` (and `actions: read` to read the
candidate). Publications are serialized per tag without canceling an active
publisher.

## Publishing protocol

Publication reuses a uniquely matching draft and preserves its title/notes, or
creates a draft with generated notes. It uploads the verified ZIP only when the
asset is absent, downloads the server copy to check size, checksum and identity,
then marks the release published. An existing draft asset is reusable only if
its bytes match the candidate. There is no asset deletion or replacement
operation. Ambiguous releases and existing prereleases require maintainer
inspection.

After successful publication, `request-cask-update` dispatches `update-cask` for
`headsetcontrol-macostray` to `ChrisLauinger77/homebrew-cask` using
`PACKAGE_REPOSITORIES_TOKEN`. It never runs for candidates.

## Retry cases

- **Candidate build/package failure:** fix the cause and start a new manual run.
  Do not rerun the failed candidate run; a rerun cannot be published.
- **Tag rejected (lightweight, missing/invalid trailer, wrong commit or run):**
  nothing was published. Delete the tag locally and on `origin`, then re-create it
  with the commands from the candidate summary.
- **Candidate artifact expired:** build a new candidate and tag that run. An
  existing unpublished tag must be deleted and re-created with the new run ID.
- **Upload failed before storing an asset:** rerun the publish job. It uploads
  only if the asset is absent.
- **Upload completed but its response was lost:** rerun the publish job. It
  verifies and reuses the stored asset instead of uploading again.
- **Incomplete (`starter`) or conflicting draft asset:** publication stops without
  deleting anything. Retry if the server is still finishing the upload; otherwise
  inspect and explicitly resolve the draft asset before retrying.
- **Publication completed but its response was lost:** rerun the publish job. It
  verifies the published asset without changing the release or its assets.
- **Cask dispatch failed after publication:** rerun only `request-cask-update`.
  It does not rebuild, upload or edit a release. Delivery is at least once: a lost
  dispatch response can cause another identical dispatch request.
- **Missing, conflicting, or unverifiable published archive:** fail for maintainer
  inspection; never repair or overwrite it automatically.

Publish-job reruns are safe: they re-resolve the same candidate and verify the
published state. Once the candidate artifact has expired they fail clearly
instead of accepting different bytes.

## Validation

Run the mocked API tests and synthetic packaging fixtures with:

```sh
node --test scripts/tests/*.test.cjs
python3 -B -m unittest discover -s scripts/tests -p 'test_*.py' -v
```

`scripts/tests/candidate.test.cjs` covers candidate source checks, tag/trailer
parsing, run and artifact verification, expiry, and checksum/manifest checks with
a mocked GitHub API. `scripts/tests/release.test.cjs` covers the resumable
publisher and exact-byte publication. The macOS fixtures compile small
arm64/x86_64 executables and exercise the actual `ditto`, `lipo`, and `codesign`
packaging path. None of these tests use headsets, GitHub credentials or real
releases. CI and every candidate run execute them.

Provenance is build evidence, not a cryptographic attestation of the build
machine. Signing, archive format and Homebrew distribution policy are unchanged.
