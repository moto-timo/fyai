// SPDX-License-Identifier: MIT
import {
	catalogueModelName,
	checkImages,
	commandsFromSchema,
	conversationBranch,
	conversationsFromBranches,
	fencedOutput,
	messageTextOf,
	parseHistory,
	parseSlashCommand,
	providerKeyEnvName,
	rewindPlan,
	sessionIdFor,
	slashCommandArgs,
	unknownCommandMessage,
	userContent
} from '../../server/protocol.mjs';
import { describe, expect, it } from 'vitest';

describe('sessionIdFor', () => {
	it('keeps a plain conversation ID', () => {
		expect(sessionIdFor('4f3a-9b_c')).toBe('4f3a-9b_c');
	});

	it('replaces the bytes that a session ID cannot hold', () => {
		expect(sessionIdFor('a/../b c')).toBe('a____b_c');
	});

	it('gives nothing for an empty ID', () => {
		expect(sessionIdFor('')).toBeNull();
		expect(sessionIdFor(undefined)).toBeNull();
	});

	it('keeps the ID within the limit of fyai', () => {
		expect(sessionIdFor('x'.repeat(200))).toHaveLength(64);
	});
});

describe('parseSlashCommand', () => {
	it('takes the name and the words after it', () => {
		expect(parseSlashCommand('/model gpt-5.5 extra')).toEqual({
			name: 'model',
			rest: ['gpt-5.5', 'extra']
		});
	});

	it('accepts a leading blank and a lower-case name', () => {
		expect(parseSlashCommand('  /Stats  ')).toEqual({ name: 'stats', rest: [] });
	});

	it('gives nothing for text that is not a command', () => {
		expect(parseSlashCommand('plain words')).toBeNull();
		expect(parseSlashCommand('')).toBeNull();
	});
});

const SCHEMA = {
	commands: [
		{ command: 'context', surfaces: ['cli', 'session'], title: 'show the context fill' },
		{ command: 'compact', surfaces: ['cli', 'session'], title: 'summarize' },
		{ command: 'model', surfaces: ['cli', 'session'], title: 'the model' },
		{ command: 'todo', surfaces: ['cli', 'session'], title: 'the todo list' },
		{
			aliases: ['switch'],
			command: 'resume',
			flags: ['interactive'],
			surfaces: ['cli', 'session']
		},
		{ command: 'init', surfaces: ['cli'], title: 'create the arena' },
		{ command: 'exit', surfaces: ['session'], title: 'leave' }
	]
};
const COMMANDS = commandsFromSchema(SCHEMA);

describe('commandsFromSchema', () => {
	it('keeps the commands that exist as a verb and a slash command', () => {
		expect(COMMANDS.map((c) => c.name)).toEqual(['context', 'compact', 'model', 'todo']);
	});

	it('leaves out a command that needs a terminal', () => {
		expect(COMMANDS.some((c) => c.name === 'resume')).toBe(false);
	});

	it('gives nothing for a document that is not a schema', () => {
		expect(commandsFromSchema(null)).toEqual([]);
		expect(commandsFromSchema({ commands: 3 })).toEqual([]);
	});
});

describe('slashCommandArgs', () => {
	it('names the session branch and the verb', () => {
		expect(slashCommandArgs('c1', { name: 'context', rest: [] }, 'gpt-5.5', [], COMMANDS)).toEqual([
			'--branch',
			'sdk/c1',
			'--model',
			'gpt-5.5',
			'context'
		]);
	});

	it('passes the words of the user as separate arguments', () => {
		expect(slashCommandArgs('c1', { name: 'compact', rest: ['a', 'b'] }, '', [], COMMANDS)).toEqual(
			['--branch', 'sdk/c1', 'compact', 'a', 'b']
		);
	});

	it('does not override the model that /model stores', () => {
		expect(
			slashCommandArgs('c1', { name: 'model', rest: ['gpt-5.5'] }, 'other', [], COMMANDS)
		).toEqual(['--branch', 'sdk/c1', 'model', 'gpt-5.5']);
	});

	it('reports the model of the session when /model has no name', () => {
		expect(slashCommandArgs('c1', { name: 'model', rest: [] }, 'other', [], COMMANDS)).toEqual([
			'--branch',
			'sdk/c1',
			'model'
		]);
	});

	it('gives no arguments for a command that the page does not serve', () => {
		expect(slashCommandArgs('c1', { name: 'nope', rest: [] }, '', [], COMMANDS)).toBeNull();
	});

	it('puts the extra arguments of the bridge before the command', () => {
		expect(
			slashCommandArgs('c1', { name: 'todo', rest: [] }, '', ['--set', 'a=b'], COMMANDS)
		).toEqual(['--set', 'a=b', '--branch', 'sdk/c1', 'todo']);
	});
});

describe('unknownCommandMessage', () => {
	it('names the commands that the page serves', () => {
		const message = unknownCommandMessage('nope', COMMANDS);

		expect(message).toContain('unknown command /nope');
		expect(message).toContain('/todo');
		expect(unknownCommandMessage('nope')).toContain('exports no commands');
	});
});

describe('providerKeyEnvName', () => {
	it('finds the catalogue name that /model typed out', () => {
		const models = [{ name: 'claude-haiku-5.5' }, { name: 'gpt-5.4' }];

		expect(catalogueModelName(models, 'claude-haiku-5.5')).toBe('claude-haiku-5.5');
		expect(catalogueModelName(models, 'GPT-5.4')).toBe('gpt-5.4');
		/* fyai and the catalogue spell the same model with different punctuation */
		expect(catalogueModelName(models, 'claude-haiku-5-5')).toBe('claude-haiku-5.5');
		/* fyai may name the provider in front of the model */
		expect(catalogueModelName(models, 'anthropic/claude-haiku-5-5')).toBe('claude-haiku-5.5');
	});

	it('gives no model for one the catalogue does not list', () => {
		expect(catalogueModelName([{ name: 'gpt-5.4' }], 'haiku')).toBe('');
		expect(catalogueModelName([{ name: 'gpt-5.4' }], '')).toBe('');
	});

	it('keeps a tag apart from the model it tags', () => {
		const models = [{ name: 'gpt-oss-120b' }, { name: 'gpt-oss-120b:batch' }];

		expect(catalogueModelName(models, 'gpt-oss-120b')).toBe('gpt-oss-120b');
		expect(catalogueModelName(models, 'gpt-oss-120b:batch')).toBe('gpt-oss-120b:batch');
		/* The tag is not punctuation to drop: it names an offering of its own. */
		expect(catalogueModelName([{ name: 'gpt-oss-120b:batch' }], 'gpt-oss-120b')).toBe('');
	});

	it('names the variable of a provider', () => {
		expect(providerKeyEnvName('anthropic')).toBe('ANTHROPIC_API_KEY');
		expect(providerKeyEnvName('openai')).toBe('OPENAI_API_KEY');
	});

	it('maps the characters that a variable name cannot hold', () => {
		expect(providerKeyEnvName('open-router')).toBe('OPEN_ROUTER_API_KEY');
		expect(providerKeyEnvName('meta.llama')).toBe('META_LLAMA_API_KEY');
	});

	it('gives nothing for a name that is not a provider', () => {
		expect(providerKeyEnvName('')).toBeNull();
		expect(providerKeyEnvName('a b')).toBeNull();
		expect(providerKeyEnvName('x'.repeat(80))).toBeNull();
	});
});

describe('fencedOutput', () => {
	it('fences the output of a command', () => {
		expect(fencedOutput({ ok: true, text: 'rows' })).toBe('```text\nrows\n```');
	});

	it('marks a failure', () => {
		expect(fencedOutput({ ok: false, text: 'gone' })).toBe(
			'**The command failed.**\n\n```text\ngone\n```'
		);
	});

	it('cannot be closed by the output itself', () => {
		expect(fencedOutput({ ok: true, text: 'a ``` b' })).toBe("```text\na ''' b\n```");
	});

	it('says something for an empty result', () => {
		expect(fencedOutput({ ok: true, text: '' })).toBe('```text\ndone\n```');
	});
});

describe('conversationsFromBranches', () => {
	it('keeps the branches of the page sessions, newest first, with the time in milliseconds', () => {
		const list = [
			{ branch: 'main', turns: 4, updated: 9e15 },
			{ branch: 'sdk/a', description: 'Title', model: 'gpt', turns: 2, updated: 2000000 },
			{ branch: 'sdk/b', description: '', model: '-', turns: 0, updated: 3000000 },
			{ branch: 'agent/x', turns: 1, updated: 5000000 }
		];

		expect(conversationsFromBranches(list)).toEqual([
			{ id: 'b', model: '', name: '', turns: 0, updated: 3000 },
			{ id: 'a', model: 'gpt', name: 'Title', turns: 2, updated: 2000 }
		]);
	});

	it('answers nothing for output that is not a list', () => {
		expect(conversationsFromBranches(null)).toEqual([]);
		expect(conversationsFromBranches({ branch: 'sdk/a' })).toEqual([]);
		expect(conversationsFromBranches([null, { branch: 7 }])).toEqual([]);
	});
});

describe('parseHistory', () => {
	it('reads one message for each line and leaves out what is not one', () => {
		const text = '{"role":"user","content":"a"}\nwarning: slow\n\n[1]\n{"type":"function_call"}\n';

		expect(parseHistory(text)).toEqual([{ content: 'a', role: 'user' }, { type: 'function_call' }]);
		expect(parseHistory('')).toEqual([]);
	});
});

describe('conversationBranch', () => {
	it('names the branch below sdk/ whatever the ID holds', () => {
		expect(conversationBranch('4f3a-9b')).toBe('sdk/4f3a-9b');
		expect(conversationBranch('../main')).toBe('sdk/___main');
		expect(conversationBranch('')).toBe('');
		expect(conversationBranch(undefined)).toBe('');
	});
});

describe('messageTextOf', () => {
	it('reads a string, the text parts of a list, and nothing else', () => {
		expect(messageTextOf({ content: 'a' })).toBe('a');
		expect(messageTextOf({ content: [{ text: 'a' }, { type: 'image' }, { text: 'b' }] })).toBe(
			'ab'
		);
		expect(messageTextOf({ content: 7 })).toBe('');
		expect(messageTextOf(null)).toBe('');
	});
});

describe('rewindPlan', () => {
	const history = [
		{ content: 'one', role: 'user' },
		{ content: 'a1', role: 'assistant' },
		{ call_id: 'k', name: 'shell', type: 'function_call' },
		{ call_id: 'k', output: 'x', type: 'function_call_output' },
		{ content: 'two', role: 'user' },
		{ content: 'a2', role: 'assistant' },
		{ content: 'one', role: 'user' },
		{ content: 'a3', role: 'assistant' }
	];

	it('cuts back to the message before the next user message', () => {
		expect(rewindPlan(history, { occurrence: 1, text: 'one' })).toEqual({
			action: 'reset',
			keep: 4
		});
		expect(rewindPlan(history, { occurrence: 1, text: 'two' })).toEqual({
			action: 'reset',
			keep: 6
		});
	});

	it('picks the equal message by its count', () => {
		expect(rewindPlan(history, { occurrence: 2, text: 'one' })).toEqual({ action: 'none' });
	});

	it('compares the text without its outer blanks', () => {
		expect(rewindPlan(history, { occurrence: 1, text: '  two\n' })).toEqual({
			action: 'reset',
			keep: 6
		});
	});

	it('cuts nothing when the anchor is the last exchange or is not there', () => {
		expect(rewindPlan(history, { occurrence: 1, text: 'missing' })).toEqual({ action: 'none' });
		expect(rewindPlan(history, { occurrence: 5, text: 'one' })).toEqual({ action: 'none' });
	});

	it('deletes the branch when the turn follows no message and the branch has some', () => {
		expect(rewindPlan(history, null)).toEqual({ action: 'delete' });
		expect(rewindPlan([], null)).toEqual({ action: 'none' });
		expect(rewindPlan([{ content: 'x', role: 'assistant' }], null)).toEqual({ action: 'none' });
	});
});

describe('checkImages', () => {
	const data = Buffer.from('abc').toString('base64');

	it('keeps the images that fyai takes, with a name', () => {
		const out = checkImages([
			{ data, mediaType: 'image/png', name: 'a.png' },
			{ data, mediaType: 'image/jpeg' },
			{ data, mediaType: 'image/gif' },
			{ data, mediaType: 'image/webp' }
		]) as { images: { mediaType: string; name: string }[] };

		expect(out.images.map((i) => i.mediaType)).toEqual([
			'image/png',
			'image/jpeg',
			'image/gif',
			'image/webp'
		]);
		expect(out.images.map((i) => i.name)).toEqual(['a.png', 'image', 'image', 'image']);
	});

	it('takes no list as no images', () => {
		expect(checkImages(undefined)).toEqual({ images: [] });
		expect(checkImages([])).toEqual({ images: [] });
	});

	it('refuses another type, data that is not base64, no data and a value that is not a list', () => {
		for (const bad of [
			[{ data, mediaType: 'image/svg+xml' }],
			[{ data, mediaType: undefined }],
			[{ data: 'a b', mediaType: 'image/png' }],
			[{ data: 7, mediaType: 'image/png' }],
			[{ data: '', mediaType: 'image/png' }],
			[null],
			'x'
		]) {
			expect(checkImages(bad)).toHaveProperty('error');
		}
	});
});

describe('userContent', () => {
	const image = { data: 'QUJD', mediaType: 'image/png', name: 'a.png' };

	it('is the text and then a block for each image', () => {
		expect(userContent('look', [image])).toEqual([
			{ text: 'look', type: 'text' },
			{
				name: 'a.png',
				source: { data: 'QUJD', media_type: 'image/png', type: 'base64' },
				type: 'image'
			}
		]);
	});

	it('has no text block when there is no text', () => {
		expect(userContent('  ', [image]).map((b) => b.type)).toEqual(['image']);
		expect(userContent('hi', []).map((b) => b.type)).toEqual(['text']);
	});
});
