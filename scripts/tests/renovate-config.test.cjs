const assert = require('node:assert/strict');
const { test } = require('node:test');
const fs = require('node:fs');
const path = require('node:path');
const { createRequire } = require('node:module');

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
    const disabled = config.packageRules.find(rule => rule.enabled === false);
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

test('actual Handlebars rendering updates version, commit and channel atomically', { skip: !tools }, () => {
    const requireTool = createRequire(path.join(tools, 'package.json'));
    const handlebars = requireTool('handlebars');
    for (const channel of ['release', 'snapshot']) {
        const source = contents.replace(/"channel": "(?:release|snapshot)"/, `"channel": "${channel}"`);
        const regex = new RegExp(manager.matchStrings[0]);
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
});
