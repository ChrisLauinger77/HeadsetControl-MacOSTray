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
        await github.rest.repos.updateRelease({ ...repo, release_id: releaseID, draft: false });
    }
    // A lost publish response is recovered by a later read, never by replacing assets.
    return { releaseID, digest, reusedPublishedRelease: false };
}

async function requestCaskUpdate(github) {
    await github.rest.repos.createDispatchEvent({ owner: 'ChrisLauinger77', repo: 'homebrew-cask',
        event_type: 'update-cask', client_payload: { cask: 'headsetcontrol-macostray' } });
}

module.exports = { ASSET_NAME, sha256, validateArchive, prepareRelease, publishRelease, requestCaskUpdate };
