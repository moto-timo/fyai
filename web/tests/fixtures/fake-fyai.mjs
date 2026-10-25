#!/usr/bin/env node
// SPDX-License-Identifier: MIT
/*
 * A stand-in for the branch verbs of fyai, for the tests of the bridge. The
 * state is a JSON file named by FAKE_FYAI_STATE: {branches: {NAME: {turns,
 * description, updated, messages: []}}}. It answers `branch list`, `history`,
 * `branch describe` and `branch delete` in the forms that fyai writes them.
 */

import { readFileSync, writeFileSync } from 'node:fs';

const file = process.env.FAKE_FYAI_STATE;
const args = process.argv.slice(2);
const state = JSON.parse(readFileSync(file, 'utf8'));
const save = () => writeFileSync(file, JSON.stringify(state));
const fail = (text) => {
	process.stderr.write(`${text}\n`);
	process.exit(1);
};

let branch = 'main';

/* The global option comes before the command. */
if (args[0] === '--branch' || args[0] === '-b') {
	branch = args[1];
	args.splice(0, 2);
}

const [command, sub, ...rest] = args;

if (command === 'branch' && sub === 'list') {
	const rows = Object.entries(state.branches).map(([name, b]) => ({
		branch: name,
		current: name === 'main',
		description: b.description ?? '',
		model: b.model ?? '-',
		turns: b.turns ?? 0,
		updated: (b.updated ?? 0) * 1000
	}));

	process.stdout.write(`${JSON.stringify(rows)}\n`);
} else if (command === 'history' && branch === 'sdk/env') {
	/* What a program of the bridge finds in its environment. */
	process.stdout.write(
		`${JSON.stringify({ content: process.env.FYAI_BRIDGE_TOKEN ?? 'unset', role: 'user' })}\n`
	);
} else if (command === 'history') {
	for (const message of state.branches[branch]?.messages ?? [])
		process.stdout.write(`${JSON.stringify(message)}\n`);
} else if (command === 'branch' && sub === 'describe') {
	const [name, ...text] = rest;

	if (!state.branches[name]) fail(`no such branch '${name}'`);

	state.branches[name].description = text.join(' ');
	save();
} else if (command === 'branch' && sub === 'delete') {
	const name = rest.filter((a) => !a.startsWith('-'))[0];

	if (!state.branches[name]) fail(`no such branch '${name}'`);

	delete state.branches[name];
	save();
}
