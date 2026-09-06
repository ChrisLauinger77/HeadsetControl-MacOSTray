# Release publication and recovery

The release workflow serializes the whole run by tag, without canceling an active
publisher. The tag must belong to `main` and match the Xcode marketing version.
Preparation reuses a uniquely matching draft and preserves its title/notes. An
existing published release skips building and packaging and enters verification
only. Ambiguous releases and existing prereleases require maintainer inspection.

Architecture archives must describe the same application identifier, executable,
package type, marketing version, build number, and minimum system version. The
minimum is compared, not changed. Packaging still combines the executables,
ad-hoc signs the app, and uses the existing `ditto` ZIP format. It validates the
finished ZIP and extracted bundle, including signature and both architectures.

The exact ZIP and its SHA-256 are retained as a `release-candidate-<attempt>`
Actions artifact for seven days. Publication downloads that artifact by ID and
checks its checksum before any upload and
downloads the server copy to check its size, checksum and tag/bundle identity.
An existing draft asset is reusable only if its bytes match the candidate.
There is no asset deletion or replacement operation in the publisher.

## Retry cases

- **Build/package failure:** rerun the failed jobs; no archive has been published.
- **Upload failed before storing an asset:** retry publication with the retained
  candidate. It uploads only if the asset is absent.
- **Upload completed but its response was lost:** retry publication. It verifies
  and reuses the stored asset instead of uploading again.
- **Incomplete (`starter`) or conflicting draft asset:** publication stops without
  deleting anything. Retry if the server is still finishing the upload; otherwise
  inspect and explicitly resolve the draft asset before retrying.
- **Publication completed but its response was lost:** retry publication. It
  verifies the published asset without changing the release or its assets.
- **Cask dispatch failed after publication:** rerun only `request-cask-update`, or
  use the existing “Request Homebrew cask update” manual workflow. Neither path
  rebuilds, uploads, or edits a release. Delivery is at least once: a lost dispatch
  response can cause another identical dispatch request.
- **Entire workflow rerun after publication:** preparation detects the published
  release, skips the build/package jobs, and verifies the existing download.
- **Missing, conflicting, or unverifiable published archive:** fail for maintainer
  inspection; never repair or overwrite it automatically. Older published assets
  without GitHub checksum metadata also require manual verification.

Prefer retrying failed publication jobs with the retained candidate. Rebuilding
a draft from scratch can produce different ZIP bytes because dependency/build
inputs are not pinned. A resulting checksum conflict is intentional. Expired
Actions artifacts require manual recovery; the publisher never silently accepts
a replacement candidate. The concurrency lock coordinates this workflow, not
manual edits or other publishers outside its concurrency group.

Rerun builds may replace their private architecture intermediates in Actions.
Each packaging attempt retains a separate final candidate; it never overwrites
an earlier candidate or a GitHub release asset.

## Validation

Run the mocked API tests and synthetic packaging fixtures with:

```sh
node --test scripts/tests/*.test.cjs
python3 -B -m unittest discover -s scripts/tests -p 'test_*.py' -v
```

The macOS fixtures compile small arm64/x86_64 executables and exercise the actual
`ditto`, `lipo`, and `codesign` packaging path. They do not use headsets or GitHub
credentials. Pure identity/API tests run without hardware or release writes.
CI runs these checks for workflow-only changes as well as application changes.

This pass does not pin dependencies/Xcode, alter deployment targets, audit native
linkage, bundle libraries, change signing/notarization, or change the cask model.
