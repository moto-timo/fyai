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

/* The global options come before the command. */
while (args[0] === '--branch' || args[0] === '-b' || args[0] === '--set') {
	if (args[0] !== '--set') branch = args[1];

	args.splice(0, 2);
}

const [command, sub, ...rest] = args;

if (args.includes('claude-sdk')) {
	const name = branch;

	process.stdin.setEncoding('utf8');
	process.stdin.once('data', (line) => {
		const blocks = JSON.parse(line.split('\n')[0]).message.content;
		const prompt = blocks
			.filter((block) => block.type === 'text')
			.map((block) => block.text)
			.join('');
		const b = (state.branches[name] ??= { bounds: [], messages: [], turns: 0, updated: 1 });
		/* The image blocks as the SDK front takes them: the type and the decoded size. */
		const images = blocks
			.filter((block) => block.type === 'image' && block.source?.type === 'base64')
			.map((block) => ({
				mediaType: block.source.media_type,
				size: Buffer.from(block.source.data, 'base64').length
			}));

		b.messages.push({ content: prompt, images, role: 'user' });
		b.bounds.push(b.messages.length);
		b.messages.push({ content: `answer to ${prompt}`, role: 'assistant' });
		b.bounds.push(b.messages.length);
		b.turns = b.bounds.length;
		save();
		process.stdout.write(
			`${JSON.stringify({ is_error: false, result: 'ok', subtype: 'success', type: 'result' })}\n`
		);
		process.exit(0);
	});
} else if (command === 'branch' && sub === 'new') {
	const [name, source] = rest;

	if (state.branches[name]) fail(`branch '${name}' exists`);

	state.branches[name] = structuredClone(state.branches[source]);
	save();
} else if (command === 'reset') {
	const b = state.branches[branch];
	const steps = Number(String(sub).split('~')[1]);

	if (!b || !steps || steps >= b.bounds.length) fail('cannot go back that far');

	/* A branch that cannot move: the reset reports success and changes nothing. */
	if (b.stuck) process.exit(0);

	b.bounds.length -= steps;
	b.messages.length = b.bounds.at(-1);
	b.turns = b.bounds.length;
	save();
} else if (command === 'branch' && sub === 'list') {
	const rows = Object.entries(state.branches).map(([name, b]) => ({
		branch: name,
		current: name === 'main',
		description: b.description ?? '',
		model: b.model ?? '-',
		turns: b.turns ?? 0,
		updated: (b.updated ?? 0) * 1000
	}));

	process.stdout.write(`${JSON.stringify(rows)}\n`);
} else if (command === 'history' && branch === 'env') {
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
