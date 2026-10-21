// SPDX-License-Identifier: MIT
import type { FyaiFrame } from '$lib/services/fyai.service';
import { FyaiTurnAssembler, toolResultText, type TurnMessage } from '$lib/services/fyai.turn';
import { describe, expect, it } from 'vitest';

function delta(text: string): FyaiFrame {
	return {
		event: {
			delta: { text, type: 'text_delta' },
			index: 0,
			type: 'content_block_delta'
		},
		type: 'stream_event'
	};
}

function assistant(blocks: Array<Record<string, unknown>>): FyaiFrame {
	return { message: { content: blocks }, type: 'assistant' };
}

function assistantText(text: string): FyaiFrame {
	return assistant([{ text, type: 'text' }]);
}

function assistantCall(id: string, name: string, input: unknown): FyaiFrame {
	return assistant([{ id, input, name, type: 'tool_use' }]);
}

function toolResult(id: string, text: string): FyaiFrame {
	return {
		message: { content: [{ content: text, tool_use_id: id, type: 'tool_result' }] },
		type: 'user'
	};
}

function result(usage: Record<string, unknown> = {}, isError = false): FyaiFrame {
	return {
		is_error: isError,
		result: isError ? 'it failed' : '',
		type: 'result',
		usage: { input_tokens: 11, output_tokens: 7, ...usage }
	};
}

function collector() {
	const messages: TurnMessage[] = [];
	const toolResults: Array<{ id: string; text: string }> = [];
	const texts: string[] = [];
	const errors: Error[] = [];
	const models: string[] = [];
	const timings: Array<{ predicted_n: number; prompt_n: number }> = [];

	let created = 0;
	let done = 0;

	return {
		counts: () => ({ created, done }),
		errors,
		messages,
		models,
		sink: {
			createMessage: () => {
				created++;
			},
			createToolResult: (id: string, text: string) => {
				toolResults.push({ id, text });
			},
			messageDone: (message: TurnMessage) => {
				done++;
				messages.push(message);
			},
			onError: (error: Error) => errors.push(error),
			onModel: (model: string) => models.push(model),
			onText: (text: string) => texts.push(text),
			onTimings: (value: { predicted_n: number; prompt_n: number }) => timings.push(value)
		},
		texts,
		timings,
		toolResults
	};
}

describe('FyaiTurnAssembler', () => {
	it('joins the deltas of one answer into one message', async () => {
		const c = collector();
		const assembler = new FyaiTurnAssembler(c.sink);

		assembler.push(delta('Alpha '));
		assembler.push(delta('beta.'));
		assembler.push(assistantText('Alpha beta.'));
		assembler.push(result());

		expect(await assembler.settled()).toBe(false);
		expect(c.messages).toEqual([{ content: 'Alpha beta.', toolCalls: [] }]);
		expect(c.texts).toEqual(['Alpha ', 'beta.']);
	});

	it('uses the text of the assistant frame when no delta arrived', async () => {
		const c = collector();
		const assembler = new FyaiTurnAssembler(c.sink);

		assembler.push(assistantText('Whole answer.'));
		assembler.push(result());

		await assembler.settled();

		expect(c.messages).toEqual([{ content: 'Whole answer.', toolCalls: [] }]);
		expect(c.texts).toEqual(['Whole answer.']);
	});

	it('opens a message per assistant frame of a turn', async () => {
		const c = collector();
		const assembler = new FyaiTurnAssembler(c.sink);

		assembler.push(delta('Looking.'));
		assembler.push(assistantCall('call_1', 'Bash', { command: 'ls' }));
		assembler.push(toolResult('call_1', 'a.txt'));
		assembler.push(delta('Done.'));
		assembler.push(assistantText('Done.'));

		await assembler.settled();

		expect(c.messages).toEqual([
			{
				content: 'Looking.',
				toolCalls: [{ arguments: '{"command":"ls"}', id: 'call_1', name: 'Bash' }]
			},
			{ content: 'Done.', toolCalls: [] }
		]);
		expect(c.toolResults).toEqual([{ id: 'call_1', text: 'a.txt' }]);
		expect(c.counts()).toEqual({ created: 1, done: 2 });
	});

	it('records a tool-only message with no text', async () => {
		const c = collector();
		const assembler = new FyaiTurnAssembler(c.sink);

		assembler.push(assistantCall('call_1', 'Read', { file_path: 'a' }));

		await assembler.settled();

		expect(c.messages).toEqual([
			{
				content: '',
				toolCalls: [{ arguments: '{"file_path":"a"}', id: 'call_1', name: 'Read' }]
			}
		]);
	});

	it('reports the model, the timings and a failed turn', async () => {
		const c = collector();
		const assembler = new FyaiTurnAssembler(c.sink);

		assembler.push({ model: 'gpt-x', subtype: 'init', type: 'system' });
		assembler.push(assistantText('Partial.'));
		assembler.push(result({}, true));

		expect(await assembler.settled()).toBe(true);
		expect(c.models).toEqual(['gpt-x']);
		expect(c.timings).toEqual([{ predicted_n: 7, prompt_n: 11 }]);
		expect(c.errors.map((error) => error.message)).toEqual(['it failed']);
	});

	it('shows the output of a slash command as a message', async () => {
		const c = collector();
		const assembler = new FyaiTurnAssembler(c.sink);

		assembler.push({ ok: true, subtype: 'command', text: '```text\nrows\n```', type: 'bridge' });

		await assembler.settled();

		expect(c.messages).toEqual([{ content: '```text\nrows\n```', toolCalls: [] }]);
	});

	it('reports an error frame of the bridge', async () => {
		const c = collector();
		const assembler = new FyaiTurnAssembler(c.sink);

		assembler.push({ message: 'no session', subtype: 'error', type: 'bridge' });

		expect(await assembler.settled()).toBe(true);
		expect(c.errors.map((error) => error.message)).toEqual(['no session']);
	});

	it('keeps the queues of two turns apart', async () => {
		const first = collector();
		const second = collector();
		const a = new FyaiTurnAssembler(first.sink);
		const b = new FyaiTurnAssembler(second.sink);

		a.push(delta('one '));
		b.push(delta('two '));
		a.push(assistantText('one '));
		b.push(assistantText('two '));

		await Promise.all([a.settled(), b.settled()]);

		expect(first.messages).toEqual([{ content: 'one ', toolCalls: [] }]);
		expect(second.messages).toEqual([{ content: 'two ', toolCalls: [] }]);
	});
});

describe('toolResultText', () => {
	it('joins the text blocks of a result', () => {
		expect(
			toolResultText([
				{ text: 'a', type: 'text' },
				{ text: 'b', type: 'text' }
			])
		).toBe('a\nb');
	});

	it('takes a plain string', () => {
		expect(toolResultText('plain')).toBe('plain');
	});

	it('gives nothing for a shape it does not know', () => {
		expect(toolResultText(null)).toBe('');
		expect(toolResultText({ text: 'x' })).toBe('');
	});
});
