const assert = require('node:assert/strict');
const { test } = require('node:test');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { ASSET_NAME, CHECKSUMS, CANDIDATE_MANIFEST, sha256, checkCandidateSource, writeCandidate,
    candidateSummary, candidateRunID, ensureReleaseTag, verifyReleaseTag, verifyCandidateFiles } = require('../release.cjs');

const repo = { owner: 'owner', repo: 'app' };
const repository = 'owner/app';
const tag = 'v3.2.2';
const commit = 'a'.repeat(40);
const runID = 4242;
const bytes = Buffer.from('universal application archive');

const notFound = () => Object.assign(new Error('Not Found'), { status: 404 });

function directory(t) {
    const result = fs.mkdtempSync(path.join(os.tmpdir(), 'candidate-test-'));
    t.after(() => fs.rmSync(result, { recursive: true, force: true }));
    return result;
}

function candidateDirectory(t, overrides = {}) {
    const result = directory(t);
    fs.writeFileSync(path.join(result, ASSET_NAME), bytes);
    writeCandidate(result, { version: '3.2.2', commit, runID, runAttempt: '1', repository, ...overrides });
    return result;
}

// Fake GitHub API for the annotated tag created on approval of one candidate run.
function api(change = () => {}) {
    const state = {
        ref: { object: { type: 'tag', sha: 'tagobject' } },
        tag: { tag, object: { type: 'commit', sha: commit }, message: `HeadsetControl-MacOSTray 3.2.2\n\nCandidate-Run: ${runID}\n` },
        existingTags: [],
    };
    change(state);
    state.github = {
        rest: {
            git: {
                getRef: async ({ ref }) => {
                    if (ref === `tags/${tag}` && !state.existingTags.length) return { data: state.ref };
                    if (state.existingTags.includes(ref)) return { data: { ref } };
                    throw notFound();
                },
                getTag: async ({ tag_sha }) => {
                    assert.equal(tag_sha, 'tagobject');
                    return { data: state.tag };
                },
            },
        },
    };
    return state;
}

const verify = state => verifyReleaseTag(state.github, repo, { tag, commit, runID });
const source = { event: 'workflow_dispatch', ref: 'refs/heads/main', defaultBranch: 'main', runAttempt: '1', version: '3.2.2' };

// Persist tag objects and references independently, including lost write responses.
function tagServer() {
    const state = { ref: null, annotations: new Map(), mutations: [], readFailure: null, referenceFailure: null };
    state.github = { rest: { git: {
        getRef: async request => {
            assert.equal(request.ref, `tags/${tag}`);
            if (state.readFailure) throw state.readFailure;
            if (!state.ref) throw notFound();
            return { data: structuredClone(state.ref) };
        },
        getTag: async ({ tag_sha }) => {
            const annotation = state.annotations.get(tag_sha);
            if (!annotation) throw notFound();
            return { data: structuredClone(annotation) };
        },
        createTag: async request => {
            state.mutations.push('annotation');
            const sha = `annotation-${state.annotations.size + 1}`;
            const annotation = { sha, tag: request.tag, message: request.message, tagger: request.tagger,
                object: { type: request.type, sha: request.object } };
            state.annotations.set(sha, annotation);
            return { data: structuredClone(annotation) };
        },
        createRef: async request => {
            state.mutations.push('reference');
            assert.equal(request.ref, `refs/tags/${tag}`);
            if (state.ref) throw Object.assign(new Error('Reference already exists'), { status: 422 });
            if (state.referenceFailure === 'before') throw new Error('connection lost');
            state.ref = { object: { type: 'tag', sha: request.sha } };
            if (state.referenceFailure === 'after') throw new Error('connection lost');
            return { data: structuredClone(state.ref) };
        },
        updateRef: async () => assert.fail('release tags must never be replaced'),
        deleteRef: async () => assert.fail('release tags must never be deleted'),
    } } };
    return state;
}

const ensureTag = state => ensureReleaseTag(state.github, repo, { tag, commit, runID });

test('candidate source yields the unreleased tag from the project version', async () => {
    assert.equal(await checkCandidateSource(api(state => { state.existingTags = ['tags/v0.0.1']; }).github, repo, source), tag);
});

test('candidate source rejects other events, branches, reruns, bad versions and released tags', async () => {
    const github = api().github;
    for (const [change, message] of [
        [{ event: 'push' }, /manual workflow run/],
        [{ ref: 'refs/heads/feature' }, /built from main/],
        [{ runAttempt: '2' }, /instead of rerunning/],
        [{ version: '3.2' }, /Invalid application version/],
        [{ version: '' }, /Invalid application version/],
    ]) {
        await assert.rejects(checkCandidateSource(github, repo, { ...source, ...change }), message);
    }
    const released = api(state => { state.existingTags = [`tags/${tag}`]; });
    await assert.rejects(checkCandidateSource(released.github, repo, source), /already exists/);
});

test('candidate files record the checksum, commit, run and version', t => {
    const result = candidateDirectory(t);
    assert.deepEqual(fs.readdirSync(result).sort(), [CHECKSUMS, ASSET_NAME, CANDIDATE_MANIFEST].sort());
    assert.equal(fs.readFileSync(path.join(result, CHECKSUMS), 'utf8'),
        `${sha256(bytes).slice('sha256:'.length)}  ${ASSET_NAME}\n`);
    assert.deepEqual(JSON.parse(fs.readFileSync(path.join(result, CANDIDATE_MANIFEST), 'utf8')),
        { repository, version: '3.2.2', tag, commit, run_id: runID, run_attempt: 1 });
});

test('candidate recording rejects reruns and unexpected files', t => {
    const result = directory(t);
    fs.writeFileSync(path.join(result, ASSET_NAME), bytes);
    assert.throws(() => writeCandidate(result, { version: '3.2.2', commit, runID, runAttempt: '2', repository }), /rerunning/);
    fs.writeFileSync(path.join(result, 'extra.zip'), bytes);
    assert.throws(() => writeCandidate(result, { version: '3.2.2', commit, runID, runAttempt: '1', repository }), /only/);
});

test('summary explains approval with the exact tag it creates', () => {
    const text = candidateSummary({ version: '3.2.2', commit, runID, digest: sha256(bytes) });
    assert.match(text, /^### Candidate ready for verification\n/);
    assert.ok(text.includes(`annotated tag \`v3.2.2\` on \`${commit}\``));
    assert.ok(text.includes(`\`HeadsetControl-MacOSTray 3.2.2\` and \`Candidate-Run: ${runID}\``));
    assert.ok(text.includes(sha256(bytes)));
    assert.doesNotMatch(text, /<[A-Z_]+>/);
    // Tagging is the approval job's work; the summary never asks for manual tag commands.
    assert.doesNotMatch(text, /git (tag|push)/);
    for (const note of [/Review deployments/, /`release`/, /30 days/, /expired/, /Reject the deployment/,
        /new manual workflow run/, /Re-run all jobs/, /tested the artifact/]) {
        assert.match(text, note);
    }
    assert.throws(() => candidateSummary({ version: '3.2.2', commit: 'HEAD', runID, digest: '' }), /full commit SHA/);
});

test('Candidate-Run trailer parsing requires exactly one positive run ID', () => {
    assert.equal(candidateRunID(`Title\n\nCandidate-Run: ${runID}`), runID);
    for (const message of ['Title', '', undefined, 'Candidate-Run: 1\nCandidate-Run: 2']) {
        assert.throws(() => candidateRunID(message), /exactly one Candidate-Run/);
    }
    for (const value of ['0', '-5', 'abc', '12 34', '1e5', '99999999999999999999', '']) {
        assert.throws(() => candidateRunID(`Candidate-Run: ${value}`), /Invalid candidate run ID/);
    }
});

test('the approval tag of this run and commit is accepted', async () => {
    await verify(api());
});

test('tag and trailer problems reject publication', async () => {
    const cases = [
        [state => { state.ref.object.type = 'commit'; }, /annotated tag/],
        [state => { state.tag.object.sha = 'b'.repeat(40); }, /does not directly annotate/],
        [state => { state.tag.object.type = 'tag'; }, /does not directly annotate/],
        [state => { state.tag.tag = 'v9.9.9'; }, /does not directly annotate/],
        [state => { state.tag.message = 'HeadsetControl-MacOSTray 3.2.2'; }, /exactly one Candidate-Run/],
        [state => { state.tag.message = 'Candidate-Run: latest'; }, /Invalid candidate run ID/],
        [state => { state.tag.message = 'Candidate-Run: 1234'; }, /names candidate run 1234, not this run 4242/],
    ];
    for (const [change, message] of cases) {
        await assert.rejects(verify(api(change)), message);
        await assert.rejects(ensureTag(api(change)), message);
    }
    await assert.rejects(verifyReleaseTag(api().github, repo, { tag: 'release-3.2.2', commit, runID }),
        /Unexpected release tag/);
    await assert.rejects(verifyReleaseTag(api(state => { state.existingTags = ['tags/v0.0.1']; }).github, repo,
        { tag, commit, runID }), /Not Found/);
});

test('approval creates an annotated tag and reuses only this run and commit', async () => {
    const state = tagServer();
    await ensureTag(state);
    const annotation = state.annotations.get(state.ref.object.sha);
    assert.equal(annotation.tag, tag);
    assert.deepEqual(annotation.object, { type: 'commit', sha: commit });
    assert.equal(candidateRunID(annotation.message), runID);
    assert.match(annotation.message, /^HeadsetControl-MacOSTray 3\.2\.2\n/);
    assert.equal(annotation.tagger.name, 'github-actions[bot]');
    const ref = structuredClone(state.ref);
    await ensureTag(state);
    assert.deepEqual(state.ref, ref);
    assert.deepEqual(state.mutations, ['annotation', 'reference']);
});

for (const failure of ['before', 'after']) {
    test(`tag reference failure (${failure}) resumes without deleting or replacing a tag`, async () => {
        const state = tagServer();
        state.referenceFailure = failure;
        await assert.rejects(ensureTag(state), /connection lost/);
        const ref = structuredClone(state.ref);
        state.referenceFailure = null;
        await ensureTag(state);
        await verify(state);
        if (failure === 'after') {
            assert.deepEqual(state.ref, ref);
            assert.deepEqual(state.mutations, ['annotation', 'reference']);
        } else {
            assert.deepEqual(state.mutations, ['annotation', 'reference', 'annotation', 'reference']);
        }
    });
}

test('tag lookup errors never create a release tag', async () => {
    for (const status of [403, 429, 503]) {
        const state = tagServer();
        state.readFailure = Object.assign(new Error('lookup failed'), { status });
        await assert.rejects(ensureTag(state), /lookup failed/);
        assert.deepEqual(state.mutations, []);
    }
});

test('a competing tag created during approval is not replaced', async () => {
    const state = tagServer();
    const create = state.github.rest.git.createRef;
    state.github.rest.git.createRef = async request => {
        state.annotations.set('competing', { tag, object: { type: 'commit', sha: commit },
            message: 'Candidate-Run: 1234' });
        state.ref = { object: { type: 'tag', sha: 'competing' } };
        return create(request);
    };
    await assert.rejects(ensureTag(state), /Reference already exists/);
    const ref = structuredClone(state.ref);
    await assert.rejects(ensureTag(state), /names candidate run 1234/);
    assert.deepEqual(state.ref, ref);
    assert.deepEqual(state.mutations, ['annotation', 'reference']);
});

test('invalid tagging inputs fail before tag creation', async () => {
    for (const change of [{ tag: 'v3.2' }, { commit: 'HEAD' }, { runID: 0 }, { runID: 'bad' },
        { runID: '0x10' }, { runID: '01' }, { runID: Number.MAX_SAFE_INTEGER + 1 }]) {
        const state = tagServer();
        await assert.rejects(ensureReleaseTag(state.github, repo, { tag, commit, runID, ...change }),
            /Unexpected release tag|full commit SHA/);
        assert.deepEqual(state.mutations, []);
    }
});

const expected = { tag, commit, runID, repository };

test('downloaded candidate files verify against their original checksum', t => {
    const result = candidateDirectory(t);
    assert.deepEqual(verifyCandidateFiles(result, expected),
        { archivePath: path.join(result, ASSET_NAME), digest: sha256(bytes) });
});

test('modified archives or checksum manifests are never accepted', t => {
    const changed = candidateDirectory(t);
    fs.writeFileSync(path.join(changed, ASSET_NAME), Buffer.from('rebuilt archive'));
    assert.throws(() => verifyCandidateFiles(changed, expected), /recorded candidate checksum/);
    const rewritten = candidateDirectory(t);
    fs.writeFileSync(path.join(rewritten, CHECKSUMS), `${'0'.repeat(64)}  ${ASSET_NAME}\n`);
    assert.throws(() => verifyCandidateFiles(rewritten, expected), /recorded candidate checksum/);
    const renamed = candidateDirectory(t);
    fs.writeFileSync(path.join(renamed, CHECKSUMS), `${sha256(bytes).slice(7)}  other.zip\n`);
    assert.throws(() => verifyCandidateFiles(renamed, expected), /must list exactly/);
});

test('incomplete or extended candidate file sets are rejected', t => {
    for (const name of [ASSET_NAME, CHECKSUMS, CANDIDATE_MANIFEST]) {
        const result = candidateDirectory(t);
        fs.rmSync(path.join(result, name));
        assert.throws(() => verifyCandidateFiles(result, expected), /must contain exactly/);
    }
    const extra = candidateDirectory(t);
    fs.writeFileSync(path.join(extra, 'notes.txt'), 'unexpected');
    assert.throws(() => verifyCandidateFiles(extra, expected), /must contain exactly/);
    assert.throws(() => verifyCandidateFiles(directory(t), expected), /found nothing/);
});

test('candidate manifest must match the tag version, commit, run and repository', t => {
    const result = candidateDirectory(t);
    for (const [change, message] of [
        [{ tag: 'v3.2.3' }, /tag/],
        [{ commit: 'b'.repeat(40) }, /commit/],
        [{ runID: 1 }, /run_id/],
        [{ repository: 'other/app' }, /repository/],
    ]) {
        assert.throws(() => verifyCandidateFiles(result, { ...expected, ...change }), message);
    }
});
