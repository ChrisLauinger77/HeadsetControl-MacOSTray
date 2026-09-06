const assert = require('node:assert/strict');
const { test } = require('node:test');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { ASSET_NAME, sha256, prepareRelease, publishRelease, requestCaskUpdate } = require('../release.cjs');

const repo = { owner: 'owner', repo: 'app' };
const tag = 'v3.1.0';
const bytes = Buffer.from('validated application archive');
const validate = (data, actualTag) => {
    assert.equal(actualTag, tag);
    assert.deepEqual(data, bytes);
};

// Stateful fake models persisted server state across failed requests and reruns.
function server() {
    const state = { releases: [], assets: [], mutations: [], uploadFailure: null,
        publishFailure: false, dispatchFailure: false };
    const repos = {
        listReleases: async () => ({ data: structuredClone(state.releases) }),
        createRelease: async request => {
            state.mutations.push('create');
            const release = { ...request, id: 1 };
            state.releases.push(release);
            return { data: structuredClone(release) };
        },
        getRelease: async request => ({ data: structuredClone(state.releases.find(item => item.id === request.release_id)) }),
        listReleaseAssets: async () => ({ data: state.assets.map(({ body, ...asset }) => structuredClone(asset)) }),
        getReleaseAsset: async request => ({ data: state.assets.find(item => item.id === request.asset_id).body }),
        uploadReleaseAsset: async request => {
            state.mutations.push('upload');
            assert.equal(state.releases[0].draft, true, 'never upload to a published release');
            if (state.uploadFailure === 'before') throw new Error('connection lost');
            state.addAsset(request.data, state.uploadFailure === 'partial' ? 'starter' : 'uploaded');
            if (state.uploadFailure) throw new Error('connection lost');
            return { data: state.assets.at(-1) };
        },
        updateRelease: async request => {
            state.mutations.push('publish');
            Object.assign(state.releases[0], request);
            if (state.publishFailure) throw new Error('publish response lost');
            return { data: structuredClone(state.releases[0]) };
        },
        createDispatchEvent: async request => {
            state.mutations.push('dispatch');
            assert.deepEqual(request, { owner: 'ChrisLauinger77', repo: 'homebrew-cask',
                event_type: 'update-cask', client_payload: { cask: 'headsetcontrol-macostray' } });
            if (state.dispatchFailure) throw new Error('dispatch failed');
        },
        deleteReleaseAsset: async () => assert.fail('assets must never be deleted'),
    };
    state.addAsset = (body = bytes, status = 'uploaded') => {
        state.assets.push({ id: state.assets.length + 1, name: ASSET_NAME,
            size: body.length, digest: sha256(body), state: status, body });
    };
    state.github = { rest: { repos }, paginate: async (method, request) => (await method(request)).data };
    return state;
}

function archive(t) {
    const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'release-test-'));
    t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
    const filename = path.join(directory, ASSET_NAME);
    fs.writeFileSync(filename, bytes);
    return filename;
}

async function run(state, archivePath) {
    const prepared = await prepareRelease(state.github, repo, tag);
    return publishRelease(state.github, repo, { tag, releaseID: prepared.releaseID,
        archivePath: prepared.published ? undefined : archivePath, expectedDigest: sha256(bytes) }, validate);
}

test('first publication verifies upload before publishing', async t => {
    const state = server();
    const result = await run(state, archive(t));
    assert.equal(result.digest, sha256(bytes));
    assert.equal(state.releases[0].draft, false);
    assert.deepEqual(state.mutations, ['create', 'upload', 'publish']);
});

test('existing draft is reused without changing its title or notes', async t => {
    const state = server();
    state.releases.push({ id: 77, tag_name: tag, draft: true, body: 'Maintainer notes', name: 'Custom title' });
    await run(state, archive(t));
    assert.equal(state.releases[0].id, 77);
    assert.equal(state.releases[0].body, 'Maintainer notes');
    assert.equal(state.releases[0].name, 'Custom title');
    assert.deepEqual(state.mutations, ['upload', 'publish']);
});

for (const failure of ['before', 'after', 'partial']) {
    test(`interrupted upload (${failure}) reconciles persisted state safely`, async t => {
        const state = server();
        const file = archive(t);
        state.uploadFailure = failure;
        await assert.rejects(run(state, file), /connection lost/);
        assert.equal(state.releases[0].draft, true);
        state.uploadFailure = null;
        if (failure === 'partial') {
            await assert.rejects(run(state, file), /upload is incomplete/);
            assert.deepEqual(state.mutations, ['create', 'upload']);
        } else {
            await run(state, file);
            assert.deepEqual(state.mutations, failure === 'before'
                ? ['create', 'upload', 'upload', 'publish'] : ['create', 'upload', 'publish']);
        }
    });
}

test('identical existing draft asset is reused without an upload', async t => {
    const state = server();
    await prepareRelease(state.github, repo, tag);
    state.addAsset();
    await run(state, archive(t));
    assert.deepEqual(state.mutations, ['create', 'publish']);
});

test('conflicting existing draft asset fails without mutation', async t => {
    const state = server();
    await prepareRelease(state.github, repo, tag);
    state.addAsset(Buffer.from('different archive'));
    await assert.rejects(run(state, archive(t)), /conflicting content/);
    assert.equal(state.releases[0].draft, true);
    assert.deepEqual(state.mutations, ['create']);
});

test('published release is verified without any upload or metadata mutation', async t => {
    const state = server();
    await run(state, archive(t));
    state.mutations = [];
    const result = await run(state);
    assert.equal(result.reusedPublishedRelease, true);
    assert.deepEqual(state.mutations, []);
});

test('published release with missing archive is never repaired automatically', async t => {
    const state = server();
    await run(state, archive(t));
    state.assets = [];
    state.mutations = [];
    await assert.rejects(run(state), /missing its archive/);
    assert.deepEqual(state.mutations, []);
});

test('published archive conflicting with a provided candidate is never overwritten', async t => {
    const state = server();
    const file = archive(t);
    await run(state, file);
    state.assets[0].body = Buffer.from('different content');
    state.assets[0].size = state.assets[0].body.length;
    state.assets[0].digest = sha256(state.assets[0].body);
    state.mutations = [];
    await assert.rejects(publishRelease(state.github, repo, { tag, releaseID: 1, archivePath: file, expectedDigest: sha256(bytes) }, validate), /conflicting content/);
    assert.deepEqual(state.mutations, []);
});

test('successful publication followed by failed dispatch retries only dispatch', async t => {
    const state = server();
    await run(state, archive(t));
    state.dispatchFailure = true;
    await assert.rejects(requestCaskUpdate(state.github), /dispatch failed/);
    state.dispatchFailure = false;
    await requestCaskUpdate(state.github);
    assert.deepEqual(state.mutations, ['create', 'upload', 'publish', 'dispatch', 'dispatch']);
});

test('repeated execution of the same tag remains verification-only after publication', async t => {
    const state = server();
    await run(state, archive(t));
    for (let count = 0; count < 3; count++) await run(state);
    assert.deepEqual(state.mutations, ['create', 'upload', 'publish']);
});

test('lost publish response resumes from the published state', async t => {
    const state = server();
    state.publishFailure = true;
    await assert.rejects(run(state, archive(t)), /publish response lost/);
    await run(state);
    assert.deepEqual(state.mutations, ['create', 'upload', 'publish']);
});

test('checksum, size and archive identity failures prevent publication', async t => {
    for (const failure of ['digest', 'size', 'identity']) {
        const state = server();
        const file = archive(t);
        const { releaseID } = await prepareRelease(state.github, repo, tag);
        state.addAsset();
        if (failure === 'digest') state.assets[0].digest = sha256(Buffer.from('corrupt'));
        if (failure === 'size') state.assets[0].size++;
        const validator = failure === 'identity' ? () => { throw new Error('Tag/version mismatch'); } : validate;
        await assert.rejects(publishRelease(state.github, repo, { tag, releaseID, archivePath: file, expectedDigest: sha256(bytes) }, validator));
        assert.deepEqual(state.mutations, ['create']);
        assert.equal(state.releases[0].draft, true);
    }
});

test('candidate changed after packaging is rejected before any API mutation', async t => {
    const state = server();
    await assert.rejects(publishRelease(state.github, repo, { tag, releaseID: 1,
        archivePath: archive(t), expectedDigest: sha256(Buffer.from('original package')) }, validate), /packaging job/);
    assert.deepEqual(state.mutations, []);
});

test('missing packaging checksum fails closed before any API mutation', async t => {
    const state = server();
    await assert.rejects(publishRelease(state.github, repo, { tag, releaseID: 1,
        archivePath: archive(t) }, validate), /requires the packaging job checksum/);
    assert.deepEqual(state.mutations, []);
});

test('older draft asset without GitHub digest is checked against candidate bytes', async t => {
    const state = server();
    await prepareRelease(state.github, repo, tag);
    state.addAsset();
    delete state.assets[0].digest;
    await run(state, archive(t));
    await assert.rejects(run(state), /no recorded checksum/);
});

test('ambiguous releases and changed release tags fail closed', async t => {
    const state = server();
    await prepareRelease(state.github, repo, tag);
    state.releases.push({ ...state.releases[0], id: 2 });
    await assert.rejects(prepareRelease(state.github, repo, tag), /Multiple releases/);
    state.releases.pop();
    state.releases[0].tag_name = 'v0.0.0';
    await assert.rejects(publishRelease(state.github, repo, { tag, releaseID: 1, archivePath: archive(t), expectedDigest: sha256(bytes) }, validate), /no longer belongs/);
    assert.deepEqual(state.mutations, ['create']);
});

test('manually published release between preparation and upload is not modified', async t => {
    const state = server();
    await prepareRelease(state.github, repo, tag);
    let reads = 0;
    const get = state.github.rest.repos.getRelease;
    state.github.rest.repos.getRelease = request => {
        if (++reads === 2) state.releases[0].draft = false;
        return get(request);
    };
    await assert.rejects(publishRelease(state.github, repo, { tag, releaseID: 1, archivePath: archive(t), expectedDigest: sha256(bytes) }, validate), /published during preparation/);
    assert.deepEqual(state.mutations, ['create']);
});
