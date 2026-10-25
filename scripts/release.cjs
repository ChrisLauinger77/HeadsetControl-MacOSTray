// Used by actions/github-script and exercised with a mocked Octokit client.
const { createHash } = require('node:crypto');
const { execFileSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const ASSET_NAME = 'HeadsetControl-MacOSTray.zip';
const RELEASE_BODY = 'The universal macOS build is ad-hoc signed but cannot be notarized without a paid Apple Developer Program membership. On first launch, Control-click HeadsetControl-MacOSTray and choose Open. See the README for additional Gatekeeper instructions.';
const sha256 = data => `sha256:${createHash('sha256').update(data).digest('hex')}`;

function validateArchive(data, tag) {
    const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'headset-release-'));
    try {
        const archive = path.join(directory, ASSET_NAME);
        fs.writeFileSync(archive, data);
        const revision = process.env.GITHUB_SHA ? ['--source-revision', process.env.GITHUB_SHA] : [];
        return JSON.parse(execFileSync('python3', ['-B', path.join(__dirname, 'release-artifact.py'),
            'archive', archive, '--tag', tag, '--universal', ...revision], { encoding: 'utf8' }));
    } finally {
        fs.rmSync(directory, { recursive: true, force: true });
    }
}

function checkRelease(release, tag) {
    if (release.tag_name !== tag) throw new Error('Release ID no longer belongs to the requested tag');
    if (release.prerelease) throw new Error('Refusing to change the existing prerelease policy');
}

async function prepareRelease(github, repo, tag) {
    // Paginate listings: the tag lookup endpoint need not expose unpublished drafts.
    const releases = await github.paginate(github.rest.repos.listReleases, { ...repo, per_page: 100 });
    const matches = releases.filter(release => release.tag_name === tag);
    if (matches.length > 1) throw new Error(`Multiple releases exist for ${tag}; resolve the ambiguity manually`);
    let release = matches[0];
    if (!release) {
        ({ data: release } = await github.rest.repos.createRelease({ ...repo, tag_name: tag,
            name: `HeadsetControl-MacOSTray ${tag}`, body: RELEASE_BODY,
            draft: true, prerelease: false, generate_release_notes: true }));
    }
    checkRelease(release, tag);
    return { releaseID: release.id, published: !release.draft };
}

async function archiveAsset(github, repo, releaseID) {
    const assets = await github.paginate(github.rest.repos.listReleaseAssets,
        { ...repo, release_id: releaseID, per_page: 100 });
    const matches = assets.filter(asset => asset.name === ASSET_NAME);
    if (matches.length > 1) throw new Error('Multiple application archives exist; refusing an ambiguous asset');
    return matches[0];
}

async function verifyAsset(github, repo, asset, tag, expected, validate) {
    if (asset.state !== 'uploaded') {
        throw new Error('Archive upload is incomplete; retry after it settles, or inspect the draft manually. No asset was deleted.');
    }
    const { data } = await github.rest.repos.getReleaseAsset({ ...repo, asset_id: asset.id,
        headers: { accept: 'application/octet-stream' } });
    const bytes = Buffer.from(data);
    const digest = sha256(bytes);
    if (bytes.length !== asset.size) throw new Error('Downloaded archive size does not match GitHub metadata');
    if (asset.digest && asset.digest !== digest) throw new Error('Downloaded archive checksum does not match GitHub metadata');
    if (expected && digest !== expected.digest) {
        throw new Error('Existing archive has conflicting content. No asset was replaced or deleted.');
    }
    if (!asset.digest && !expected) {
        throw new Error('Published archive has no recorded checksum; manual verification is required');
    }
    validate(bytes, tag);
    return digest;
}

async function publishRelease(github, repo, { tag, releaseID, archivePath, expectedDigest }, validate = validateArchive) {
    // Validate the exact bytes that will be uploaded, before any release mutation.
    let candidate;
    if (archivePath) {
        if (!/^sha256:[a-f0-9]{64}$/.test(expectedDigest || '')) {
            throw new Error('A publication candidate requires the packaging job checksum');
        }
        if (path.basename(archivePath) !== ASSET_NAME) throw new Error(`Expected archive named ${ASSET_NAME}`);
        const data = fs.readFileSync(archivePath);
        validate(data, tag);
        candidate = { data, digest: sha256(data) };
        if (candidate.digest !== expectedDigest) {
            throw new Error('Publication candidate checksum differs from the packaging job');
        }
    }
    const getRelease = async () => {
        const { data } = await github.rest.repos.getRelease({ ...repo, release_id: releaseID });
        checkRelease(data, tag);
        return data;
    };
    let release = await getRelease();
    let asset = await archiveAsset(github, repo, releaseID);
    if (!release.draft) {
        if (!asset) throw new Error('Published release is missing its archive; refusing to mutate it');
        const digest = await verifyAsset(github, repo, asset, tag, candidate, validate);
        return { releaseID, digest, reusedPublishedRelease: true };
    }
    if (!candidate) throw new Error('A draft release requires a validated local archive');
    if (!asset) {
        // Recheck before uploading; workflow concurrency serializes all our publishers.
        release = await getRelease();
        if (!release.draft) throw new Error('Release was published during preparation; rerun to verify it');
        await github.rest.repos.uploadReleaseAsset({ ...repo, release_id: releaseID,
            name: ASSET_NAME, data: candidate.data,
            headers: { 'content-type': 'application/zip', 'content-length': candidate.data.length } });
        // Verify the server copy even when the upload response reports success.
        asset = await archiveAsset(github, repo, releaseID);
        if (!asset) throw new Error('Uploaded archive is not visible yet; rerun to reconcile the upload');
    }
    const digest = await verifyAsset(github, repo, asset, tag, candidate, validate);
    release = await getRelease();
    if (release.draft) {
        // Let GitHub order releases by version/date at publication time, including
        // candidates approved out of order. The default promotes any new publication.
        await github.rest.repos.updateRelease({ ...repo, release_id: releaseID, draft: false, make_latest: 'legacy' });
    }
    // A lost publish response is recovered by a later read, never by replacing assets.
    return { releaseID, digest, reusedPublishedRelease: false };
}

async function requestCaskUpdate(github) {
    await github.rest.repos.createDispatchEvent({ owner: 'ChrisLauinger77', repo: 'homebrew-cask',
        event_type: 'update-cask', client_payload: { cask: 'headsetcontrol-macostray' } });
}

// Gated release: a manual run builds and retains a candidate, then waits for approval.
// The approved run tags its source commit and publishes the candidate's exact bytes without rebuilding.
const PROJECT_NAME = 'HeadsetControl-MacOSTray';
const CANDIDATE_ARTIFACT = 'release-assets';
const CHECKSUMS = 'SHA256SUMS';
const CANDIDATE_MANIFEST = 'candidate.json';
const RETENTION_DAYS = 30;
const VERSION_PATTERN = /^[0-9]+\.[0-9]+\.[0-9]+$/;

const isNotFound = error => error?.status === 404;

async function checkCandidateSource(github, repo, { event, ref, defaultBranch, runAttempt, version }) {
    if (event !== 'workflow_dispatch') throw new Error('Release candidates are built only by a manual workflow run');
    if (ref !== `refs/heads/${defaultBranch}`) throw new Error(`Release candidates must be built from ${defaultBranch}`);
    if (Number(runAttempt) !== 1) throw new Error('Start a new manual workflow run instead of rerunning a candidate');
    if (!VERSION_PATTERN.test(version || '')) throw new Error(`Invalid application version: ${version}`);
    const tag = `v${version}`;
    try {
        await github.rest.git.getRef({ ...repo, ref: `tags/${tag}` });
    } catch (error) {
        if (isNotFound(error)) return tag;
        throw error;
    }
    throw new Error(`${tag} already exists; bump MARKETING_VERSION before building a new candidate`);
}

// Records the verified candidate next to its archive. Publication never regenerates these files.
function writeCandidate(directory, { version, commit, runID, runAttempt, repository }) {
    if (Number(runAttempt) !== 1) throw new Error('Start a new manual workflow run instead of rerunning a candidate');
    const names = fs.readdirSync(directory);
    if (names.length !== 1 || names[0] !== ASSET_NAME) throw new Error(`Candidate directory must contain only ${ASSET_NAME}`);
    const digest = sha256(fs.readFileSync(path.join(directory, ASSET_NAME)));
    fs.writeFileSync(path.join(directory, CHECKSUMS), `${digest.slice('sha256:'.length)}  ${ASSET_NAME}\n`);
    const manifest = { repository, version, tag: `v${version}`, commit, run_id: Number(runID), run_attempt: 1 };
    fs.writeFileSync(path.join(directory, CANDIDATE_MANIFEST), JSON.stringify(manifest, null, 2) + '\n');
    return { digest, manifest };
}

function candidateSummary({ version, commit, runID, digest }) {
    if (!VERSION_PATTERN.test(version) || !/^[a-f0-9]{40}$/.test(commit) || !/^[1-9][0-9]*$/.test(String(runID))) {
        throw new Error('Candidate summary requires a version, full commit SHA and run ID');
    }
    const tag = `v${version}`;
    return [
        '### Candidate ready for verification',
        '',
        `While this run waits for approval, download and test its complete \`${CANDIDATE_ARTIFACT}\` artifact.`,
        `It contains \`${ASSET_NAME}\` (\`${digest}\`), \`${CHECKSUMS}\` and \`${CANDIDATE_MANIFEST}\`.`,
        '',
        'When satisfied, choose **Review deployments** on this run, select `release` and approve it.',
        `Approval creates the annotated tag \`${tag}\` on \`${commit}\` with the message ` +
            `\`${PROJECT_NAME} ${version}\` and \`Candidate-Run: ${runID}\`.`,
        'The run then publishes these exact bytes without rebuilding and requests the Homebrew cask update.',
        '',
        `- Source commit: \`${commit}\``,
        `- Candidate run: \`${runID}\``,
        `- The \`${CANDIDATE_ARTIFACT}\` artifact is retained for ${RETENTION_DAYS} days (subject to repository limits), ` +
            'and an unanswered approval request fails after 30 days. An expired candidate cannot be published.',
        '- Only approve after you have tested the artifact. Reject the deployment to discard this candidate.',
        '- For a different candidate, start a new manual workflow run. Never use "Re-run all jobs": candidate reruns are rejected.',
        '',
    ].join('\n');
}

function candidateRunID(message) {
    const trailers = String(message || '').split('\n').map(line => line.trim()).filter(line => /^Candidate-Run:/i.test(line));
    if (trailers.length !== 1) throw new Error('Tag message must contain exactly one Candidate-Run: <run ID> line');
    const match = /^Candidate-Run: ([1-9][0-9]{0,18})$/.exec(trailers[0]);
    if (!match || !Number.isSafeInteger(Number(match[1]))) throw new Error(`Invalid candidate run ID: ${trailers[0]}`);
    return Number(match[1]);
}

// Reconcile a lost tag-creation response without replacing any existing reference.
async function ensureReleaseTag(github, repo, { tag, commit, runID }) {
    if (!/^v[0-9]+\.[0-9]+\.[0-9]+$/.test(tag || '')) throw new Error(`Unexpected release tag: ${tag}`);
    if (!/^[a-f0-9]{40}$/.test(commit || '') || !/^[1-9][0-9]*$/.test(String(runID)) ||
        !Number.isSafeInteger(Number(runID))) {
        throw new Error('Release tagging requires a full commit SHA and a positive candidate run ID');
    }
    try {
        await github.rest.git.getRef({ ...repo, ref: `tags/${tag}` });
    } catch (error) {
        // Authentication and transport failures must never be mistaken for absence.
        if (!isNotFound(error)) throw error;
        const { data: annotation } = await github.rest.git.createTag({ ...repo, tag,
            message: `${PROJECT_NAME} ${tag.slice(1)}\n\nCandidate-Run: ${runID}\n`,
            object: commit, type: 'commit',
            tagger: { name: 'github-actions[bot]', email: '41898283+github-actions[bot]@users.noreply.github.com' } });
        // Create only: a concurrent/conflicting tag must never be updated or deleted.
        await github.rest.git.createRef({ ...repo, ref: `refs/tags/${tag}`, sha: annotation.sha });
    }
    await verifyReleaseTag(github, repo, { tag, commit, runID });
}

// Verify the tag created on approval: tag → annotated tag object → candidate commit and this run.
async function verifyReleaseTag(github, repo, { tag, commit, runID }) {
    if (!/^v[0-9]+\.[0-9]+\.[0-9]+$/.test(tag || '')) throw new Error(`Unexpected release tag: ${tag}`);
    const { data: ref } = await github.rest.git.getRef({ ...repo, ref: `tags/${tag}` });
    if (ref.object?.type !== 'tag') throw new Error(`${tag} must be an annotated tag with a Candidate-Run line`);
    const { data: tagObject } = await github.rest.git.getTag({ ...repo, tag_sha: ref.object.sha });
    if (tagObject.tag !== tag || tagObject.object?.type !== 'commit' || tagObject.object.sha !== commit) {
        throw new Error(`${tag} does not directly annotate the candidate commit ${commit}`);
    }
    const taggedRunID = candidateRunID(tagObject.message);
    if (taggedRunID !== Number(runID)) throw new Error(`${tag} names candidate run ${taggedRunID}, not this run ${runID}`);
}

// Verify downloaded candidate files against the manifests recorded by the candidate run.
function verifyCandidateFiles(directory, { tag, commit, runID, repository }) {
    const expected = [ASSET_NAME, CANDIDATE_MANIFEST, CHECKSUMS].sort();
    const names = fs.readdirSync(directory).sort();
    if (JSON.stringify(names) !== JSON.stringify(expected)) {
        throw new Error(`Candidate must contain exactly ${expected.join(', ')}; found ${names.join(', ') || 'nothing'}`);
    }
    const manifest = JSON.parse(fs.readFileSync(path.join(directory, CANDIDATE_MANIFEST), 'utf8'));
    const wanted = { repository, tag, version: tag.slice(1), commit, run_id: runID, run_attempt: 1 };
    for (const [key, value] of Object.entries(wanted)) {
        if (manifest[key] !== value) throw new Error(`Candidate manifest ${key} is ${JSON.stringify(manifest[key])}; expected ${JSON.stringify(value)}`);
    }
    const lines = fs.readFileSync(path.join(directory, CHECKSUMS), 'utf8').split('\n').filter(Boolean);
    const match = lines.length === 1 && /^([a-f0-9]{64}) {2}(.+)$/.exec(lines[0]);
    if (!match || match[2] !== ASSET_NAME) throw new Error(`${CHECKSUMS} must list exactly ${ASSET_NAME}`);
    const archivePath = path.join(directory, ASSET_NAME);
    const digest = sha256(fs.readFileSync(archivePath));
    if (digest !== `sha256:${match[1]}`) throw new Error(`${ASSET_NAME} does not match its recorded candidate checksum`);
    return { archivePath, digest };
}

module.exports = { ASSET_NAME, CANDIDATE_ARTIFACT, CHECKSUMS, CANDIDATE_MANIFEST, sha256, validateArchive,
    prepareRelease, publishRelease, requestCaskUpdate, checkCandidateSource, writeCandidate, candidateSummary,
    candidateRunID, ensureReleaseTag, verifyReleaseTag, verifyCandidateFiles };
