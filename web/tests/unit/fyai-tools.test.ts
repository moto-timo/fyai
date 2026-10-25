// SPDX-License-Identifier: MIT
import type { FyaiFrame } from '$lib/services/fyai.service';
import { fyaiToolView, toolResultForCard } from '$lib/services/fyai.tools';
import { FyaiTurnAssembler, type TurnMessage } from '$lib/services/fyai.turn';
import { describe, expect, it } from 'vitest';

describe('fyaiToolView', () => {
	it('shows Bash as the shell card with the command', () => {
		const view = fyaiToolView('Bash', { command: 'ls -l', timeout: 5 });

		expect(view.name).toBe('exec_shell_command');
		expect(JSON.parse(view.arguments)).toEqual({ command: 'ls -l', timeout: 5 });
	});

	it('shows Read and Write with the path the card reads', () => {
		const read = fyaiToolView('Read', { file_path: '/a.c', limit: 10 });
		const write = fyaiToolView('Write', { content: 'x', file_path: '/a.c' });

		expect(read.name).toBe('read_file');
		expect(JSON.parse(read.arguments)).toEqual({ limit: 10, path: '/a.c' });
		expect(write.name).toBe('write_file');
		expect(JSON.parse(write.arguments)).toEqual({ content: 'x', path: '/a.c' });
	});

	it('shows Edit as one edit of the edit card', () => {
		const view = fyaiToolView('Edit', { file_path: '/a.c', new_string: 'b', old_string: 'a' });

		expect(view.name).toBe('edit_file');
		expect(JSON.parse(view.arguments)).toEqual({
			edits: [{ new_text: 'b', old_text: 'a' }],
			path: '/a.c'
		});
	});

	it('keeps the name and input of any other tool', () => {
		const view = fyaiToolView('apply_patch', { patch: 'x' });

		expect(view.name).toBe('apply_patch');
		expect(JSON.parse(view.arguments)).toEqual({ patch: 'x' });
	});

	it('accepts an input that is not an object', () => {
		expect(fyaiToolView('Bash', null).arguments).toBe('{}');
		expect(fyaiToolView('Other', 'text').arguments).toBe('{}');
	});
});

describe('toolResultForCard', () => {
	it('keeps a result that succeeded', () => {
		expect(toolResultForCard('ok', false)).toBe('ok');
	});

	it('makes a failed result an object with an error', () => {
		expect(JSON.parse(toolResultForCard('no such file', true))).toEqual({
			error: 'no such file'
		});
		expect(JSON.parse(toolResultForCard('', true)).error).toBeTruthy();
	});
});

function run(frames: FyaiFrame[]) {
	const messages: TurnMessage[] = [];
	const results: string[] = [];
	const reasoning: string[] = [];
	const assembler = new FyaiTurnAssembler({
		createMessage: () => {},
		createToolResult: (_id, text) => {
			results.push(text);
		},
		messageDone: (m) => {
			messages.push(m);
		},
		onReasoning: (t) => reasoning.push(t)
	});

	for (const frame of frames) assembler.push(frame);

	return assembler.settled().then(() => ({ messages, reasoning, results }));
}

const thinkingDelta = (thinking: string): FyaiFrame => ({
	event: { delta: { thinking, type: 'thinking_delta' }, type: 'content_block_delta' },
	type: 'stream_event'
});

describe('the assembler and the fidelity of a turn', () => {
	it('collects the thinking deltas of a message', async () => {
		const out = await run([
			thinkingDelta('Let me '),
			thinkingDelta('see.'),
			{ message: { content: [{ text: 'Done.', type: 'text' }] }, type: 'assistant' }
		]);

		expect(out.reasoning).toEqual(['Let me ', 'see.']);
		expect(out.messages[0]).toMatchObject({ content: 'Done.', reasoning: 'Let me see.' });
	});

	it('takes the thinking of the assistant frame when no delta came', async () => {
		const out = await run([
			{
				message: {
					content: [
						{ thinking: 'Hmm.', type: 'thinking' },
						{ text: 'Yes.', type: 'text' }
					]
				},
				type: 'assistant'
			}
		]);

		expect(out.reasoning).toEqual(['Hmm.']);
		expect(out.messages[0].reasoning).toBe('Hmm.');
	});

	it('does not count the thinking twice when both the deltas and the frame have it', async () => {
		const out = await run([
			thinkingDelta('Once.'),
			{
				message: { content: [{ thinking: 'Once.', type: 'thinking' }] },
				type: 'assistant'
			}
		]);

		expect(out.messages[0].reasoning).toBe('Once.');
	});

	it('shows a failed tool result as an error', async () => {
		const out = await run([
			{
				message: {
					content: [{ content: 'boom', is_error: true, tool_use_id: 't1', type: 'tool_result' }]
				},
				type: 'user'
			}
		]);

		expect(JSON.parse(out.results[0])).toEqual({ error: 'boom' });
	});

	it('gives each message the usage of its own frame', async () => {
		const out = await run([
			{
				message: {
					content: [{ text: 'one', type: 'text' }],
					usage: { input_tokens: 100, output_tokens: 5 }
				},
				type: 'assistant'
			},
			{
				message: {
					content: [{ text: 'two', type: 'text' }],
					usage: { input_tokens: 120, output_tokens: 9 }
				},
				type: 'assistant'
			},
			{ message: { content: [{ text: 'three', type: 'text' }] }, type: 'assistant' }
		]);

		expect(out.messages.map((m) => m.usage)).toEqual([
			{ predicted_n: 5, prompt_n: 100 },
			{ predicted_n: 9, prompt_n: 120 },
			undefined
		]);
	});

	it('names the tools of the message as the cards know them', async () => {
		const out = await run([
			{
				message: {
					content: [{ id: 'c1', input: { command: 'ls' }, name: 'Bash', type: 'tool_use' }]
				},
				type: 'assistant'
			}
		]);

		expect(out.messages[0].toolCalls).toEqual([
			{ arguments: '{"command":"ls"}', id: 'c1', name: 'exec_shell_command' }
		]);
	});
});
