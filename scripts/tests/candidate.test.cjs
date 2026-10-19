const assert = require('node:assert/strict');
const { test } = require('node:test');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { ASSET_NAME, CHECKSUMS, CANDIDATE_MANIFEST, sha256, checkCandidateSource, writeCandidate,
    candidateSummary, candidateRunID, resolveCandidate, verifyCandidateFiles } = require('../release.cjs');

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

// Fake GitHub API for one annotated tag, its candidate run and that run's artifacts.
function api(change = () => {}) {
    const state = {
        ref: { object: { type: 'tag', sha: 'tagobject' } },
        tag: { tag, object: { type: 'commit', sha: commit }, message: `HeadsetControl-MacOSTray 3.2.2\n\nCandidate-Run: ${runID}\n` },
        runs: {
            9000: { id: 9000, workflow_id: 17 },
            [runID]: { id: runID, workflow_id: 17, path: '.github/workflows/release.yml', event: 'workflow_dispatch',
                head_branch: 'main', head_sha: commit, status: 'completed', conclusion: 'success', run_attempt: 1,
                repository: { full_name: repository }, head_repository: { full_name: repository } },
        },
        artifacts: [{ id: 55, name: 'release-assets', expired: false, size_in_bytes: 1234,
            workflow_run: { id: runID, head_sha: commit } }],
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
            actions: {
                getWorkflowRun: async ({ run_id }) => {
                    if (!state.runs[run_id]) throw notFound();
                    return { data: structuredClone(state.runs[run_id]) };
                },
                listWorkflowRunArtifacts: async ({ run_id }) => {
                    assert.equal(run_id, runID);
                    return { data: structuredClone(state.artifacts) };
                },
            },
        },
        paginate: async (method, request) => (await method(request)).data,
    };
    return state;
}

const resolve = state => resolveCandidate(state.github, repo, { tag, commit, currentRunID: 9000, defaultBranch: 'main' });
const source = { event: 'workflow_dispatch', ref: 'refs/heads/main', defaultBranch: 'main', runAttempt: '1', version: '3.2.2' };

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

test('summary prints exact tagging commands with real values', () => {
    const text = candidateSummary({ version: '3.2.2', commit, runID, digest: sha256(bytes) });
    assert.match(text, /^### Candidate ready for verification\n/);
    assert.ok(text.includes([
        '```bash',
        `git tag -a v3.2.2 ${commit} \\`,
        '  -m "HeadsetControl-MacOSTray 3.2.2" \\',
        `  -m "Candidate-Run: ${runID}"`,
        '',
        'git push origin v3.2.2',
        '```',
    ].join('\n')));
    assert.doesNotMatch(text, /<[A-Z_]+>/);
    for (const note of [/30 days/, /expires/, /new manual workflow run/, /Do not rerun/, /tested and approved/]) {
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

test('a verified first-attempt candidate resolves to its release-assets artifact', async () => {
    assert.deepEqual(await resolve(api()), { runID, artifactID: 55 });
    const suffixed = api(state => { state.runs[runID].path = '.github/workflows/release.yml@main'; });
    assert.deepEqual(await resolve(suffixed), { runID, artifactID: 55 });
});

test('tag and trailer problems reject the candidate', async () => {
    const cases = [
        [state => { state.ref.object.type = 'commit'; }, /annotated tag/],
        [state => { state.tag.object.sha = 'b'.repeat(40); }, /does not directly annotate/],
        [state => { state.tag.object.type = 'tag'; }, /does not directly annotate/],
        [state => { state.tag.tag = 'v9.9.9'; }, /does not directly annotate/],
        [state => { state.tag.message = 'HeadsetControl-MacOSTray 3.2.2'; }, /exactly one Candidate-Run/],
        [state => { state.tag.message = 'Candidate-Run: latest'; }, /Invalid candidate run ID/],
        [state => { state.tag.message = 'Candidate-Run: 1234'; }, /does not exist/],
    ];
    for (const [change, message] of cases) await assert.rejects(resolve(api(change)), message);
    await assert.rejects(resolveCandidate(api().github, repo, { tag: 'release-3.2.2', commit, currentRunID: 9000, defaultBranch: 'main' }),
        /Unexpected release tag/);
});

test('candidate run identity, outcome and provenance are verified', async () => {
    const run = change => state => change(state.runs[runID]);
    const cases = [
        [run(r => { r.repository.full_name = 'other/app'; }), /repository/],
        [run(r => { r.head_repository.full_name = 'fork/app'; }), /head repository/],
        [run(r => { r.path = '.github/workflows/ci.yml'; }), /workflow path/],
        [run(r => { r.path = '.github/workflows/ci.yml@main'; }), /workflow path/],
        [run(r => { delete r.path; }), /workflow path/],
        [run(r => { r.workflow_id = 18; }), /workflow ID/],
        [run(r => { r.event = 'push'; }), /event/],
        [run(r => { r.head_branch = 'feature'; }), /branch/],
        [run(r => { r.status = 'in_progress'; r.conclusion = null; }), /status/],
        [run(r => { r.conclusion = 'failure'; }), /conclusion/],
        [run(r => { r.conclusion = 'cancelled'; }), /conclusion/],
        [run(r => { r.run_attempt = 2; }), /run attempt/],
        [run(r => { r.head_sha = 'b'.repeat(40); }), /source commit/],
    ];
    for (const [change, message] of cases) await assert.rejects(resolve(api(change)), message);
});

test('missing, ambiguous, expired, empty and foreign artifacts are rejected', async () => {
    const artifact = change => state => change(state.artifacts[0], state);
    const cases = [
        [state => { state.artifacts = []; }, /exactly one release-assets/],
        [artifact(a => { a.name = 'app-arm64'; }), /exactly one release-assets/],
        [state => { state.artifacts.push({ ...state.artifacts[0], id: 56 }); }, /exactly one release-assets/],
        [artifact(a => { a.expired = true; }), /expired; start a new manual workflow run/],
        [artifact(a => { a.size_in_bytes = 0; }), /empty/],
        [artifact(a => { a.workflow_run.id = 1; }), /does not belong/],
        [artifact(a => { a.workflow_run.head_sha = 'b'.repeat(40); }), /does not belong/],
    ];
    for (const [change, message] of cases) await assert.rejects(resolve(api(change)), message);
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
