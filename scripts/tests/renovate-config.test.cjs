const assert = require('node:assert/strict');
const { test } = require('node:test');
const fs = require('node:fs');
const path = require('node:path');
const { createRequire } = require('node:module');
const { pathToFileURL } = require('node:url');

const root = path.resolve(__dirname, '../..');
const config = JSON.parse(fs.readFileSync(path.join(root, 'renovate.json'), 'utf8'));
const contents = fs.readFileSync(path.join(root, 'build-contract.json'), 'utf8');
const tools = process.env.DEPENDENCY_TOOLS;
const manager = config.customManagers.find(item => item.datasourceTemplate === 'github-releases');

test('HeadsetControl uses official releases and retains digest pinning without automerge', () => {
    assert.equal(config.automerge, false);
    assert.ok(config.extends.includes('github>ChrisLauinger77/ChrisLauinger77//renovate-config/default'));
    assert.ok(config.extends.includes('helpers:pinGitHubActionDigests'));
    assert.equal(manager.versioningTemplate, 'semver');
    assert.deepEqual(manager.managerFilePatterns, ['/^build-contract\\.json$/']);
    const pinRule = config.packageRules.find(rule => rule.pinDigests);
    assert.equal(pinRule.automerge, false);
    assert.equal(pinRule.ignoreUnstable, true);
    const disabled = config.packageRules.find(rule => rule.matchUpdateTypes?.includes('rollback'));
    for (const type of ['digest', 'pinDigest', 'pin', 'rollback']) assert.ok(disabled.matchUpdateTypes.includes(type));
    assert.ok(!JSON.stringify(manager).includes('HEAD'));
    for (const channel of ['release', 'snapshot']) {
        const source = contents.replace(/"channel": "(?:release|snapshot)"/, `"channel": "${channel}"`);
        const matches = [...source.matchAll(new RegExp(manager.matchStrings[0], 'g'))];
        assert.equal(matches.length, 1);
        assert.equal(matches[0].groups.depName, 'Sapd/HeadsetControl');
        assert.match(matches[0].groups.currentDigest, /^[a-f0-9]{40}$/);
        assert.equal(matches[0].groups.currentValue, JSON.parse(source).headsetcontrol.version);
    }
});

function contractFixtures() {
    const contract = JSON.parse(contents);
    const lookalike = { ...contract.headsetcontrol, repository: contract.hidapi.repository };
    return [
        contract,
        { ...contract, headsetcontrol: { ...contract.headsetcontrol, channel: 'snapshot' } },
        // Deliberately version-like metadata and another release-shaped object.
        { ...contract, schema: '9.8.7', macos: '26.0.0', xcode: { version: '99.0.0', build: '123.4.5' },
            hidapi: { ...lookalike, linkage: '1.2.3' }, metadata: { ...lookalike } },
    ];
}

test('contract extraction ignores all metadata and rejects another repository in the HeadsetControl entry', () => {
    for (const contract of contractFixtures()) {
        const source = JSON.stringify(contract, null, 2);
        const matches = [...source.matchAll(new RegExp(manager.matchStrings[0], 'g'))];
        assert.equal(matches.length, 1);
        assert.equal(matches[0].groups.depName, 'Sapd/HeadsetControl');
        assert.equal(matches[0].groups.currentValue, contract.headsetcontrol.version);
        assert.equal(matches[0].groups.currentDigest, contract.headsetcontrol.revision);
        delete contract.headsetcontrol;
        assert.equal(new RegExp(manager.matchStrings[0]).test(JSON.stringify(contract, null, 2)), false);
    }
    const contract = JSON.parse(contents);
    contract.headsetcontrol.repository = contract.hidapi.repository;
    assert.equal(new RegExp(manager.matchStrings[0]).test(JSON.stringify(contract, null, 2)), false);
});

let renovateRuntime;
function loadRenovate() {
    return renovateRuntime ??= (async () => {
        const load = relative => import(pathToFileURL(path.join(tools, 'node_modules/renovate/dist', relative + '.js')));
        const [defaults, { GlobalConfig }, { mergeChildConfig }, { getManagerConfig }, presets, memory,
            { getMatchingFiles }, managers, { applyPackageRules }] = await Promise.all([
            load('config/defaults'), load('config/global'), load('config/utils'), load('config/index'),
            load('config/presets/index'), load('util/cache/memory/index'),
            load('workers/repository/extract/file-match'), load('modules/manager/index'), load('util/package-rules/index'),
        ]);
        GlobalConfig.set({ platform: 'github', localDir: root });
        // Resolve the actual inherited preset chain offline, using a captured shared preset.
        // Built-in presets, config merging, extraction and rule matching come from CI's Renovate.
        // Source: ChrisLauinger77/ChrisLauinger77, renovate-config/default.json,
        // Git blob 32f66217ea3d886281a7886c9bcb81c63b94f6fa (2026-09-06).
        const inherited = JSON.parse(fs.readFileSync(path.join(__dirname, 'fixtures/renovate-shared-preset.json'), 'utf8'));
        memory.init();
        memory.set('preset:github>ChrisLauinger77/ChrisLauinger77//renovate-config/default', inherited);
        const resolved = await presets.resolveConfigPresets(structuredClone(config));
        const effective = mergeChildConfig(defaults.getConfig(), resolved.config);
        return { effective, getManagerConfig, mergeChildConfig, getMatchingFiles, managers, applyPackageRules };
    })();
}

test('Renovate with inherited presets extracts only HeadsetControl from the contract', { skip: !tools }, async () => {
    const { effective, getManagerConfig, mergeChildConfig, getMatchingFiles, managers } = await loadRenovate();
    const matchedManagers = [];
    for (const name of managers.getEnabledManagersList(effective.enabledManagers)) {
        const base = { ...getManagerConfig(effective, name), manager: name };
        const variants = name === 'regex' || name === 'jsonata'
            ? effective.customManagers.filter(item => item.customType === name).map(item => mergeChildConfig(base, item))
            : [base];
        for (const variant of variants) {
            if (getMatchingFiles(variant, ['build-contract.json']).length) matchedManagers.push(variant);
        }
    }
    assert.equal(matchedManagers.length, 1, 'no built-in or inherited manager may scan the contract');
    assert.equal(matchedManagers[0].manager, 'regex');
    assert.deepEqual(getMatchingFiles(matchedManagers[0], ['build-contract.json', 'nested/build-contract.json', 'BuildProvenance.json']), ['build-contract.json']);
    for (const contract of contractFixtures()) {
        const result = await managers.extractPackageFile('regex', JSON.stringify(contract, null, 2), 'build-contract.json', matchedManagers[0]);
        assert.equal(result.deps.length, 1);
        assert.equal(result.deps[0].depName, 'Sapd/HeadsetControl');
        assert.equal(result.deps[0].currentDigest, contract.headsetcontrol.revision);
        assert.equal(result.deps[0].currentValue, contract.headsetcontrol.version);
        delete contract.headsetcontrol;
        assert.equal(await managers.extractPackageFile('regex', JSON.stringify(contract, null, 2), 'build-contract.json', matchedManagers[0]), null);
    }
});

test('Renovate rules allow only HeadsetControl release updates in the contract', { skip: !tools }, async () => {
    const { effective, applyPackageRules } = await loadRenovate();
    const apply = dep => applyPackageRules({ ...effective, packageFile: 'build-contract.json',
        manager: 'regex', datasource: 'github-releases', packageName: dep.depName, ...dep });
    for (const updateType of ['major', 'minor', 'patch']) {
        const result = await apply({ depName: 'Sapd/HeadsetControl', updateType });
        assert.equal(result.enabled, true);
        assert.equal(result.pinDigests, true);
        assert.equal(result.automerge, false);
    }
    for (const updateType of ['digest', 'pinDigest', 'pin', 'rollback']) {
        assert.equal((await apply({ depName: 'Sapd/HeadsetControl', updateType })).enabled, false);
    }
    for (const depName of ['macos', 'xcode', 'libusb/hidapi', 'hidapi', 'linkage', 'schema', 'version', 'revision', 'channel', 'metadata']) {
        assert.equal((await apply({ depName, updateType: 'major' })).enabled, false, depName);
    }
    assert.equal((await apply({ depName: 'Sapd/HeadsetControl', manager: 'jsonata' })).enabled, false);
    assert.equal((await apply({ depName: 'Sapd/HeadsetControl', datasource: 'github-tags' })).enabled, false);
});

test('actual workflow runners are disabled while SHA-pinned Actions remain enabled', { skip: !tools }, async () => {
    const { effective, getManagerConfig, managers, applyPackageRules } = await loadRenovate();
    let runnerCount = 0;
    let actionCount = 0;
    for (const file of fs.readdirSync(path.join(root, '.github/workflows')).filter(file => /\.ya?ml$/.test(file))) {
        const packageFile = '.github/workflows/' + file;
        const result = await managers.extractPackageFile('github-actions', fs.readFileSync(path.join(root, packageFile), 'utf8'), packageFile,
            getManagerConfig(effective, 'github-actions'));
        for (const dep of result?.deps ?? []) {
            const configured = await applyPackageRules({ ...effective, packageName: dep.depName, ...dep,
                packageFile, manager: 'github-actions', updateType: 'major' });
            if (dep.datasource === 'github-runners') {
                runnerCount++;
                assert.equal(configured.enabled, false, `${packageFile}: ${dep.depName}`);
            } else if (dep.depType === 'action') {
                actionCount++;
                assert.match(dep.currentDigest, /^[a-f0-9]{40}$/);
                assert.equal(configured.enabled, true, dep.depName);
                assert.equal(configured.pinDigests, true, dep.depName);
                assert.equal(configured.automerge, false, dep.depName);
            }
        }
    }
    assert.ok(runnerCount > 0, 'reproduce the macOS runner dependencies shown in the Dashboard');
    assert.ok(actionCount > 0, 'continue maintaining pinned action references');
});

test('actual RE2 extraction and Handlebars rendering update the release atomically', { skip: !tools }, () => {
    const requireTool = createRequire(path.join(tools, 'package.json'));
    const handlebars = requireTool('handlebars');
    const RE2 = requireTool('re2');
    assert.throws(() => new RE2('(?=unsupported)'), 'require native RE2 rather than RegExp fallback');
    for (const channel of ['release', 'snapshot']) {
        const source = contents.replace(/"channel": "(?:release|snapshot)"/, `"channel": "${channel}"`);
        const regex = new RE2(manager.matchStrings[0]);
        const extracted = source.match(regex).groups;
        const replacement = handlebars.compile(manager.autoReplaceStringTemplate)({ ...extracted, newDigest: 'b'.repeat(40), newValue: '4.2.0' });
        const updated = JSON.parse(source.replace(regex, () => replacement));
        const expected = JSON.parse(source);
        expected.headsetcontrol = { ...expected.headsetcontrol, revision: 'b'.repeat(40), version: '4.2.0', channel: 'release' };
        assert.deepEqual(updated, expected);
        const withoutDigest = handlebars.compile(manager.autoReplaceStringTemplate)({ ...extracted, newValue: '4.2.0' });
        assert.equal(JSON.parse('{' + withoutDigest + '}').headsetcontrol.revision, '', 'missing digest fails contract validation instead of accepting an old snapshot SHA');
    }
});

test('workflow YAML is valid, actions are SHA-pinned, and snapshot selection is manual', { skip: !tools }, () => {
    const requireTool = createRequire(path.join(tools, 'package.json'));
    const yaml = requireTool('yaml');
    const directory = path.join(root, '.github/workflows');
    const workflows = {};
    for (const file of fs.readdirSync(directory).filter(file => /\.ya?ml$/.test(file))) {
        const text = fs.readFileSync(path.join(directory, file), 'utf8');
        const parsed = yaml.parseDocument(text, { uniqueKeys: true });
        assert.deepEqual(parsed.errors, [], file);
        workflows[file] = parsed.toJS();
        for (const job of Object.values(workflows[file].jobs)) {
            for (const step of job.steps ?? []) {
                if (step.uses) assert.match(step.uses, /^[\w.-]+\/[\w./-]+@[a-f0-9]{40}$/, file);
            }
        }
    }
    const snapshot = workflows['update-headsetcontrol.yml'];
    assert.deepEqual(Object.keys(snapshot.on), ['workflow_dispatch']);
    assert.equal(snapshot.concurrency['cancel-in-progress'], false);
    const job = snapshot.jobs['update-headsetcontrol-snapshot'];
    assert.match(job.if, /github\.event\.repository\.default_branch/);
    assert.ok(job.steps.some(step => step.run === 'python3 -B scripts/update_headsetcontrol.py'));
    const ciSteps = workflows['swift.yml'].jobs.build.steps;
    assert.ok(ciSteps.some(step => step.run?.includes('dependency_channels.py --base-branch "$BASE_BRANCH"')));
    assert.ok(ciSteps.some(step => step.env?.BASE_BRANCH === '${{ github.base_ref }}'));
    assert.ok(ciSteps.some(step => step.with?.script?.includes("'--strict', '--no-global', 'renovate.json'")));
});
