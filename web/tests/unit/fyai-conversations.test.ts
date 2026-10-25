// SPDX-License-Identifier: MIT
import { MessageRole } from '$lib/enums';
import {
	deleteFyaiConversation,
	fyaiConversationRows,
	fyaiSessionId,
	renameFyaiConversation,
	storedImageBytes
} from '$lib/services/fyai.conversations';
import { afterEach, describe, expect, it, vi } from 'vitest';

const ids = () => {
	let n = 0;

	return () => `id${++n}`;
};
const summary = { id: 'c1', model: '', name: '', turns: 2, updated: 10_000 };

describe('fyaiSessionId', () => {
	it('keeps the bytes of a branch name and makes the rest an underscore', () => {
		expect(fyaiSessionId('4f3a-9b_c')).toBe('4f3a-9b_c');
		expect(fyaiSessionId('a/../b c')).toBe('a____b_c');
		expect(fyaiSessionId('x'.repeat(100))).toHaveLength(64);
	});
});

describe('fyaiConversationRows', () => {
	it('chains a root and each message under the one before', () => {
		const { conv, messages } = fyaiConversationRows(
			summary,
			[
				{ content: 'Hi', role: 'user' },
				{ content: 'Hello', role: 'assistant' }
			],
			ids()
		);

		expect(messages.map((m) => [m.role, m.type, m.content])).toEqual([
			['system', 'root', ''],
			['user', 'text', 'Hi'],
			['assistant', 'text', 'Hello']
		]);
		expect(messages[0].parent).toBeNull();
		expect(messages[1].parent).toBe(messages[0].id);
		expect(messages[0].children).toEqual([messages[1].id]);
		expect(conv.currNode).toBe(messages[2].id);
		expect(conv.id).toBe('c1');
		expect(conv.name).toBe('Hi');
	});

	it('puts a call on the assistant message before it and its result under it', () => {
		const { messages } = fyaiConversationRows(
			summary,
			[
				{ content: 'Run ls', role: 'user' },
				{ content: 'Listing.', role: 'assistant' },
				{ arguments: '{"command":"ls"}', call_id: 'k1', name: 'shell', type: 'function_call' },
				{ call_id: 'k1', output: 'a.txt\n', type: 'function_call_output' },
				{ content: 'Done.', role: 'assistant' }
			],
			ids()
		);
		const assistant = messages[2];
		const calls = JSON.parse(assistant.toolCalls!);

		expect(calls).toEqual([
			{
				function: { arguments: '{"command":"ls"}', name: 'exec_shell_command' },
				id: 'k1',
				type: 'function'
			}
		]);
		expect(messages[3]).toMatchObject({
			content: 'a.txt\n',
			role: MessageRole.TOOL,
			toolCallId: 'k1'
		});
		expect(messages[4]).toMatchObject({ content: 'Done.', role: 'assistant' });
	});

	it('gathers parallel calls on one message and opens one when no text came first', () => {
		const { messages } = fyaiConversationRows(
			summary,
			[
				{ content: 'go', role: 'user' },
				{ arguments: '{"path":"a"}', call_id: 'k1', name: 'read_file', type: 'function_call' },
				{ arguments: '{"path":"b"}', call_id: 'k2', name: 'read_file', type: 'function_call' }
			],
			ids()
		);

		expect(messages).toHaveLength(3);
		expect(JSON.parse(messages[2].toolCalls!).map((c: { id: string }) => c.id)).toEqual([
			'k1',
			'k2'
		]);
		expect(messages[2].content).toBe('');
	});

	it('keeps the text parts of a message and leaves out what has no row', () => {
		const { messages } = fyaiConversationRows(
			summary,
			[
				{ content: 'System prompt', role: 'system' },
				{
					content: [
						{ text: 'look ', type: 'text' },
						{ digest: 'x', type: 'image' },
						{ text: 'here', type: 'text' }
					],
					role: 'user'
				},
				{ type: 'reasoning' },
				null
			],
			ids()
		);

		expect(messages.map((m) => m.content)).toEqual(['', 'look here']);
	});

	it('names the conversation after the branch description, else its first line', () => {
		const stored = [{ content: '\n  First line\nsecond', role: 'user' }];

		expect(fyaiConversationRows({ ...summary, name: 'Mine' }, stored, ids()).conv.name).toBe(
			'Mine'
		);
		expect(fyaiConversationRows(summary, stored, ids()).conv.name).toBe('First line');
		expect(fyaiConversationRows(summary, [], ids()).conv.name).toBe('Conversation');
	});

	it('dates the rows in order, ending at the update of the branch', () => {
		const { conv, messages } = fyaiConversationRows(
			summary,
			[
				{ content: 'a', role: 'user' },
				{ content: 'b', role: 'assistant' }
			],
			ids()
		);
		const times = messages.map((m) => m.timestamp);

		expect([...times].sort((a, b) => a - b)).toEqual(times);
		expect(times.at(-1)).toBeLessThan(summary.updated);
		expect(conv.lastModified).toBe(summary.updated);
	});
});

describe('a call in the form of Chat Completions', () => {
	const stored = [
		{ content: 'Make a plan', role: 'user' },
		{
			content: null,
			role: 'assistant',
			tool_calls: [
				{ function: { arguments: '{"todos":[]}', name: 'todo_write' }, id: 'c1', type: 'function' },
				{ function: { arguments: '{"command":"ls"}', name: 'shell' }, id: 'c2', type: 'function' }
			]
		},
		{ content: 'todo list updated', role: 'tool', tool_call_id: 'c1' },
		{ content: 'a.txt\n', role: 'tool', tool_call_id: 'c2' },
		{ content: 'Done.', role: 'assistant' }
	];

	it('puts the calls on the assistant message and each result under it', () => {
		const { messages } = fyaiConversationRows(summary, stored, ids());
		const calls = JSON.parse(messages[2].toolCalls!);

		expect(messages.map((m) => m.role)).toEqual([
			'system',
			'user',
			'assistant',
			'tool',
			'tool',
			'assistant'
		]);
		expect(calls.map((c: { id: string }) => c.id)).toEqual(['c1', 'c2']);
		expect(calls.map((c: { function: { name: string } }) => c.function.name)).toEqual([
			'todo_write',
			'exec_shell_command'
		]);
		expect(messages[3]).toMatchObject({ content: 'todo list updated', toolCallId: 'c1' });
		expect(messages[4]).toMatchObject({ content: 'a.txt\n', toolCallId: 'c2' });
		expect(messages[5].content).toBe('Done.');
	});

	it('leaves a plain assistant message with no calls', () => {
		const { messages } = fyaiConversationRows(
			summary,
			[{ content: 'hi', role: 'assistant' }],
			ids()
		);

		expect(messages[1].toolCalls).toBe('');
	});
});

describe('the images of a stored message', () => {
	const bytes = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x7f, 0x80, 0xff];
	/* As the JSON of `history` writes them: a high byte is a lone surrogate. */
	const stored = bytes.map((b) => String.fromCharCode(b < 0x80 ? b : 0xdc00 + b)).join('');

	it('reads the bytes that the JSON of history writes', () => {
		expect([...storedImageBytes(stored)!]).toEqual(bytes);
	});

	it('reads a valid UTF-8 sequence among the bytes as the bytes it came from', () => {
		/* 0xC4 0x89 is U+0109, and 0xF0 0x9F 0x98 0x80 is U+1F600: both are valid UTF-8. */
		expect([...storedImageBytes('a\u0109\u{1f600}\udcff')!]).toEqual([
			0x61, 0xc4, 0x89, 0xf0, 0x9f, 0x98, 0x80, 0xff
		]);
	});

	it('refuses a surrogate that is not an escaped byte', () => {
		expect(storedImageBytes('\ud83d')).toBeNull();
		expect(storedImageBytes('\udc7f')).toBeNull();
	});

	it('makes the image an attachment of the user message', () => {
		const { messages } = fyaiConversationRows(
			summary,
			[
				{
					content: [
						{ text: 'what is this', type: 'text' },
						{ data: stored, media_type: 'image/png', name: 'shot.png', type: 'image' }
					],
					role: 'user'
				}
			],
			ids()
		);
		const [extra] = messages[1].extra as Array<{ base64Url: string; name: string; size: number }>;

		expect(messages[1].content).toBe('what is this');
		expect(extra.name).toBe('shot.png');
		expect(extra.size).toBe(bytes.length);
		expect(extra.base64Url).toBe(`data:image/png;base64,${Buffer.from(bytes).toString('base64')}`);
	});

	it('leaves out an image that cannot be read and gives a plain message no attachment', () => {
		const { messages } = fyaiConversationRows(
			summary,
			[
				{ content: [{ data: '\ud83d', media_type: 'image/png', type: 'image' }], role: 'user' },
				{ content: 'plain', role: 'user' }
			],
			ids()
		);

		expect(messages[1].extra).toBeUndefined();
		expect(messages[2].extra).toBeUndefined();
	});
});

describe('a rename or a delete of a conversation with no branch', () => {
	const answer = (status: number, message = 'no such branch') =>
		vi.stubGlobal(
			'fetch',
			vi.fn(async () => new Response(JSON.stringify({ error: { message } }), { status }))
		);

	afterEach(() => vi.unstubAllGlobals());

	it('is not a failure: there is nothing to change', async () => {
		answer(404);

		await expect(renameFyaiConversation('c1', 'name')).resolves.toBeUndefined();
		await expect(deleteFyaiConversation('c1')).resolves.toBeUndefined();
	});

	it('reports any other failure with its cause', async () => {
		answer(502, 'fyai is gone');

		await expect(renameFyaiConversation('c1', 'name')).rejects.toThrow('fyai is gone');
		await expect(deleteFyaiConversation('c1')).rejects.toThrow('fyai is gone');
	});

	it('names the conversation in the path and sends the title as JSON', async () => {
		answer(200);
		await renameFyaiConversation('a b', 'Title');

		const [url, init] = (fetch as unknown as ReturnType<typeof vi.fn>).mock.calls[0];

		expect(url).toBe('/api/fyai/conversations/a%20b');
		expect(init).toMatchObject({ body: '{"name":"Title"}', method: 'PATCH' });
	});
});
