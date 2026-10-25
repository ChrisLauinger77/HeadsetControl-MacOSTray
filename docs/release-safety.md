# Release publication and recovery

Releases run as one manual run of `.github/workflows/release.yml`: build once,
test the candidate, approve it, then let the same run tag the exact source commit
and publish the already verified bytes.

## Stage 1: build a candidate

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
7. Writes the approval instructions, source commit, run ID and checksum to the job
   summary.

These candidate jobs have read-only repository permissions, no secrets, and never
create releases, tags or package-repository updates. Candidate runs do not share
a concurrency group, so they never cancel each other.

## Approving and tagging

After the candidate jobs finish, the `approve-and-tag` job waits for approval of
the `release` environment. Download the complete `release-assets` artifact from
the waiting run and test it. When satisfied, open the run, choose **Review
deployments**, select `release` and approve. To discard the candidate, reject the
deployment instead.

On approval, `approve-and-tag` creates the annotated tag as `github-actions[bot]`
using the GitHub API. An existing tag is reused only if it directly annotates the
validated source commit and has exactly one `Candidate-Run` line naming this run.
A lightweight tag, another commit or another candidate run fails without changing
the existing tag. A new tag names the validated source commit (not the current
`main`), equivalent to:

```bash
git tag -a v3.2.2 <validated source commit> \
  -m "HeadsetControl-MacOSTray 3.2.2" \
  -m "Candidate-Run: <this run ID>"

git push origin refs/tags/v3.2.2
```

The tag is created with `GITHUB_TOKEN`, which does not start another workflow run.
Do not create or push release tags manually; a manually pushed tag publishes
nothing.

- Approve before the artifact expires (30 days, subject to repository limits). An
  unanswered approval request also fails after 30 days.
- For a different candidate, start a **new** manual run. Never use “Re-run all
  jobs” on a candidate run: it can make the tested artifact unavailable, and the
  candidate jobs reject reruns.

The `release` environment must require a reviewer (with self-review allowed for a
single maintainer) and should only accept deployments from `main`.

## Stage 2: publish the candidate

The `publish` job runs in the same workflow run after `approve-and-tag` succeeds
and builds nothing. Before any release mutation it verifies:

- the tag matches the Xcode marketing version at the candidate commit;
- `refs/tags/vX.Y.Z` is an annotated tag that directly annotates the candidate
  commit and contains exactly one `Candidate-Run: <run ID>` line naming this run.

It downloads this run's `release-assets` artifact and requires exactly the three
files above. `candidate.json` must match the tag, version, commit, run and
repository, and the ZIP must match its original `SHA256SUMS` entry. Checksums are
never regenerated. The ZIP is validated again (bundle identity, tag version,
embedded source revision, both architecture slices) before upload.

Only `approve-and-tag` and `publish` have `contents: write`; `approve-and-tag`
only runs after environment approval. A version's tag can be created only once, so
two candidates for the same version can never both publish.

## Publishing protocol

Publication reuses a uniquely matching draft and preserves its title/notes, or
creates a draft with generated notes. It uploads the verified ZIP only when the
asset is absent, downloads the server copy to check size, checksum and identity,
then marks the release published. An existing draft asset is reusable only if
its bytes match the candidate. There is no asset deletion or replacement
operation. Ambiguous releases and existing prereleases require maintainer
inspection.

Publication explicitly uses [GitHub's `make_latest: legacy` policy](https://docs.github.com/en/rest/releases/releases#update-a-release), which orders
releases by version and date instead of promoting whichever candidate is approved
last. If an older candidate is approved after a newer release, the older version
can still be published without replacing the newer latest release. GitHub applies
this ordering when publishing, so there is no client-side latest-lookup race.
Published-release retries only verify existing bytes and do not change this policy.
The Homebrew updater follows the latest release, so the older publication does not
downgrade the cask.

After successful publication, `request-cask-update` dispatches `update-cask` for
`headsetcontrol-macostray` to `ChrisLauinger77/homebrew-cask` using
`PACKAGE_REPOSITORIES_TOKEN`. It never runs for candidates.

## Retry cases

Recover a failed approval or publication with “Re-run failed jobs” on the same
run. That keeps this run's `release-assets` artifact; the candidate jobs are not
rerun.

- **Candidate build/package failure:** fix the cause and start a new manual run.
  Do not rerun the failed candidate run; a rerun cannot be published.
- **Approval rejected or timed out:** nothing was tagged or published. Start a new
  manual run, or use “Re-run failed jobs” to request approval for the same
  candidate again while its artifact is retained.
- **Tag already exists when approving:** a matching annotation for this commit and
  candidate run is verified and reused. A conflicting tag fails without publication;
  inspect it, then bump `MARKETING_VERSION` and build a new candidate, or explicitly
  resolve the unpublished conflicting tag before using “Re-run failed jobs”.
- **Tag creation failed or its response was lost:** use “Re-run failed jobs”;
  approval is requested again. If the reference was stored, it is verified and
  reused. Otherwise a new annotated tag is created. No tag is deleted or replaced.
- **Tag rejected by `publish` (not annotated, wrong commit or run):** nothing was
  published. Delete the tag on `origin`, then re-run the `approve-and-tag` job
  (which also reruns `publish`) to recreate it after a new approval.
- **Candidate artifact expired:** build a new candidate. An existing unpublished
  tag must be deleted first.
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

Publish-job reruns are safe: they re-verify the same tag and candidate and the
published state. Once the candidate artifact has expired they fail instead of
accepting different bytes.

## Validation

Run the mocked API tests and synthetic packaging fixtures with:

```sh
node --test scripts/tests/*.test.cjs
python3 -B -m unittest discover -s scripts/tests -p 'test_*.py' -v
```

`scripts/tests/candidate.test.cjs` covers candidate source checks, the approval
summary, tag/trailer parsing and verification, and checksum/manifest checks with
a mocked GitHub API, including lost tag-reference responses and conflicting tags.
`scripts/tests/test_native_contract.py` checks the workflow's
job order, approval gate and permissions. `scripts/tests/release.test.cjs` covers the resumable
publisher, exact-byte publication and the latest-release policy when another
candidate publishes first. The macOS fixtures compile small
arm64/x86_64 executables and exercise the actual `ditto`, `lipo`, and `codesign`
packaging path. None of these tests use headsets, GitHub credentials or real
releases. CI and every candidate run execute them.

Provenance is build evidence, not a cryptographic attestation of the build
machine. Signing, archive format and Homebrew distribution policy are unchanged.
