// SPDX-License-Identifier: MIT
import { MessageRole } from '$lib/enums';
import { fyaiConversationRows, fyaiSessionId } from '$lib/services/fyai.conversations';
import { describe, expect, it } from 'vitest';

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
