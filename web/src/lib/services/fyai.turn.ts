// SPDX-License-Identifier: MIT
/**
 * FyaiTurnAssembler - the frames of one fyai turn, assembled into messages.
 *
 * fyai runs the whole tool loop of a turn itself, so one response carries
 * several assistant messages, each with its text and tool calls, and the
 * results of those calls. This class turns that stream into rows: one row
 * per assistant message, and a tool result row per call.
 *
 * The work of a frame is queued, because a sink writes to the page while
 * frames keep arriving. State belongs to the open segment and is set where
 * the text is appended, never where a frame arrives: a queued segment opens
 * after the frame that started it.
 */

import type { FyaiFrame } from '$lib/services/fyai.service';

export interface TurnToolCall {
	arguments: string;
	id: string;
	name: string;
}

export interface TurnMessage {
	content: string;
	toolCalls: TurnToolCall[];
}

export interface TurnTimings {
	predicted_n: number;
	prompt_n: number;
}

export interface TurnSink {
	/** Start the row of the next assistant message. */
	createMessage?: () => Promise<unknown> | unknown;
	/** A tool result, with the ID of the call that produced it. */
	createToolResult?: (toolUseId: string, text: string) => Promise<unknown> | unknown;
	onError?: (error: Error) => void;
	onModel?: (model: string) => void;
	/** `/model NAME` succeeded: the session now uses this model. */
	onCommandModel?: (model: string) => void;
	onText?: (text: string) => void;
	/** The open assistant message is complete. */
	messageDone: (message: TurnMessage) => Promise<unknown> | unknown;
	onTimings?: (timings: TurnTimings) => void;
}

/** The text of a tool result, which the protocol sends as text blocks. */
export function toolResultText(content: unknown): string {
	if (typeof content === 'string') return content;

	if (!Array.isArray(content)) return '';

	return content
		.filter(
			(block): block is { type?: string; text?: string } => !!block && typeof block === 'object'
		)
		.filter((block) => block.type === 'text')
		.map((block) => block.text ?? '')
		.join('\n');
}

export class FyaiTurnAssembler {
	private content = '';
	private failed = false;
	private firstSegment = true;
	private queue: Promise<void> = Promise.resolve();
	private segmentHasText = false;
	private segmentOpen = false;
	private timings: TurnTimings | undefined;
	private toolCalls: TurnToolCall[] = [];

	/** True once a failure frame or a sink error was seen. */
	get hasFailed(): boolean {
		return this.failed;
	}

	constructor(private sink: TurnSink) {}

	push(frame: FyaiFrame): void {
		switch (frame.type) {
			case 'system':
				if (frame.subtype === 'init' && typeof frame.model === 'string') {
					this.sink.onModel?.(frame.model);
				}

				break;

			case 'stream_event':
				this.pushStreamEvent(frame);

				break;

			case 'assistant':
				this.pushAssistant(frame);

				break;

			case 'user':
				this.pushToolResults(frame);

				break;

			case 'result':
				this.pushResult(frame);

				break;

			case 'bridge':
				this.pushBridge(frame);

				break;
		}
	}

	/** Wait for the work of every frame that was pushed. */
	async settled(): Promise<boolean> {
		await this.queue;

		return this.failed;
	}

	private append(text: string): void {
		this.content += text;
		this.segmentHasText = true;
		this.sink.onText?.(text);
	}

	private async beginSegment(): Promise<void> {
		if (this.segmentOpen) return;

		if (!this.firstSegment) await this.sink.createMessage?.();

		this.firstSegment = false;
		this.segmentOpen = true;
		this.content = '';
		this.segmentHasText = false;
		this.toolCalls = [];
	}

	private enqueue(work: () => Promise<void>): void {
		this.queue = this.queue.then(work).catch((error: unknown) => {
			this.failed = true;
			this.sink.onError?.(error instanceof Error ? error : new Error(String(error)));
		});
	}

	private fail(error: Error): void {
		this.failed = true;
		this.enqueue(async () => {
			this.sink.onError?.(error);
		});
	}

	private async finishSegment(): Promise<void> {
		await this.sink.messageDone({ content: this.content, toolCalls: this.toolCalls });
		this.segmentOpen = false;
		this.content = '';
		this.segmentHasText = false;
		this.toolCalls = [];
	}

	private pushAssistant(frame: FyaiFrame): void {
		const message = frame.message as
			| { content?: Array<Record<string, unknown>>; usage?: Record<string, unknown> }
			| undefined;
		const blocks = Array.isArray(message?.content) ? message.content : [];
		const text = blocks
			.filter((block) => block.type === 'text')
			.map((block) => String(block.text ?? ''))
			.join('');
		const calls: TurnToolCall[] = blocks
			.filter((block) => block.type === 'tool_use')
			.map((block) => ({
				arguments: JSON.stringify(block.input ?? {}),
				id: String(block.id ?? ''),
				name: String(block.name ?? '')
			}));

		this.enqueue(async () => {
			await this.beginSegment();

			/* Without partial messages the text comes only here. */
			if (!this.segmentHasText && text) this.append(text);

			this.toolCalls.push(...calls);
			await this.finishSegment();
		});
	}

	private pushBridge(frame: FyaiFrame): void {
		/* A slash command answers with its output, not with a turn. */
		if (frame.subtype === 'command' && typeof frame.text === 'string') {
			const text = frame.text;

			if (typeof frame.model === 'string' && frame.model) this.sink.onCommandModel?.(frame.model);

			this.enqueue(async () => {
				await this.beginSegment();
				this.append(text);
				await this.finishSegment();
			});

			return;
		}

		if (frame.subtype === 'error') this.fail(bridgeError(frame));
	}

	private pushResult(frame: FyaiFrame): void {
		const usage = (frame.usage ?? {}) as Record<string, unknown>;

		this.timings = {
			predicted_n: Number(usage.output_tokens) || 0,
			prompt_n: Number(usage.input_tokens) || 0
		};
		this.sink.onTimings?.(this.timings);

		if (frame.is_error) this.fail(resultError(frame));
	}

	private pushStreamEvent(frame: FyaiFrame): void {
		const event = frame.event as
			| { type?: string; delta?: { type?: string; text?: string } }
			| undefined;

		if (
			event?.type !== 'content_block_delta' ||
			event.delta?.type !== 'text_delta' ||
			typeof event.delta.text !== 'string'
		)
			return;

		const text = event.delta.text;

		this.enqueue(async () => {
			await this.beginSegment();
			this.append(text);
		});
	}

	private pushToolResults(frame: FyaiFrame): void {
		const message = frame.message as { content?: unknown } | undefined;
		const blocks = Array.isArray(message?.content) ? message.content : [];

		for (const block of blocks as Array<Record<string, unknown>>) {
			if (block?.type !== 'tool_result') continue;

			const text = toolResultText(block.content);
			const toolUseId = String(block.tool_use_id ?? '');

			this.enqueue(async () => {
				await this.sink.createToolResult?.(toolUseId, text);
			});
		}
	}
}

function resultError(frame: FyaiFrame): Error {
	return new Error(
		typeof frame.result === 'string' && frame.result
			? frame.result
			: 'fyai did not complete the turn'
	);
}

function bridgeError(frame: FyaiFrame): Error {
	return new Error(
		typeof frame.message === 'string' && frame.message ? frame.message : 'the bridge ended the turn'
	);
}
