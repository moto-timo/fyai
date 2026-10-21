// SPDX-License-Identifier: MIT
/**
 * FyaiService - the transport of one fyai turn.
 *
 * The browser cannot start a process, so the local bridge runs one
 * `fyai claude-sdk` per turn and streams the frames of the Claude Agent
 * SDK protocol here. This module reads that stream and gives each frame to
 * the caller. It holds no state: the conversation lives in fyai, keyed by
 * the session ID, which is the conversation ID of the page.
 */

import { AttachmentType, ContentPartType } from '$lib/enums';
import type { DatabaseMessage, DatabaseMessageExtra } from '$lib/types';
import type { ApiChatMessageContentPart } from '$lib/types/api';

/** A frame of the Agent SDK protocol, or a state frame of the bridge. */
export interface FyaiFrame {
	type: string;
	[key: string]: unknown;
}

export interface FyaiTurnRequest {
	conversationId: string;
	/**
	 * Keys by provider name, from the Provider API keys setting. The bridge
	 * puts each one in the environment of its fyai process as
	 * `<PROVIDER>_API_KEY`, so a conversation can move between providers. It
	 * does not store them.
	 */
	providerKeys?: Record<string, string>;
	/**
	 * The key of the API Key setting. It belongs to the provider of the
	 * selected model, which the bridge resolves.
	 */
	apiKey?: string;
	/** The session does not exist yet: start it rather than resume it. */
	fresh: boolean;
	model?: string | null;
	permissionMode?: string;
	prompt: string;
}

export class FyaiHttpError extends Error {
	status: number;

	constructor(message: string, status: number) {
		super(message);
		this.name = 'FyaiHttpError';
		this.status = status;
	}
}

const SSE_DATA_PREFIX = 'data:';

/**
 * Runs one turn and calls `onFrame` for each frame the bridge sends. Resolves
 * when the response ends; the caller reads the final state from the frames.
 *
 * @throws FyaiHttpError when the bridge rejects the request, and the abort
 * reason when `signal` stops the turn.
 */
export async function streamFyaiTurn(
	request: FyaiTurnRequest,
	onFrame: (frame: FyaiFrame) => void,
	signal?: AbortSignal
): Promise<void> {
	const response = await fetch('/api/fyai/chat', {
		body: JSON.stringify(request),
		headers: { 'content-type': 'application/json' },
		method: 'POST',
		signal
	});

	if (!response.ok) {
		let message = `the bridge answered ${response.status}`;

		try {
			const body = (await response.json()) as { error?: { message?: string } };

			if (body?.error?.message) message = body.error.message;
		} catch {
			/* A body that is not JSON leaves the status as the reason. */
		}

		throw new FyaiHttpError(message, response.status);
	}

	if (!response.body) throw new Error('the bridge sent no body');

	const reader = response.body.getReader();
	const decoder = new TextDecoder();

	let buffer = '';

	for (;;) {
		const { done, value } = await reader.read();

		if (done) break;

		buffer += decoder.decode(value, { stream: true });

		let nl: number;

		while ((nl = buffer.indexOf('\n')) >= 0) {
			const line = buffer.slice(0, nl).trimEnd();

			buffer = buffer.slice(nl + 1);

			/* Blank rows and the `: ping` comment of a keep-alive. */
			if (!line.startsWith(SSE_DATA_PREFIX)) continue;

			const data = line.slice(SSE_DATA_PREFIX.length).trim();

			if (!data) continue;

			let frame: FyaiFrame;

			try {
				frame = JSON.parse(data) as FyaiFrame;
			} catch {
				continue;
			}

			onFrame(frame);
		}
	}
}

/** The text of a message content, which is a string or a list of parts. */
export function messageText(content: string | ApiChatMessageContentPart[]): string {
	if (typeof content === 'string') return content;

	if (!Array.isArray(content)) return '';

	return content
		.map((part) => (part.type === ContentPartType.TEXT ? (part.text ?? '') : ''))
		.join('');
}

function extraText(extra: DatabaseMessageExtra): string {
	switch (extra.type) {
		case AttachmentType.TEXT:
			return `\n\nFile ${extra.name}:\n\`\`\`\n${extra.content}\n\`\`\``;
		case AttachmentType.PDF:
			return `\n\nFile ${extra.name}:\n\`\`\`\n${extra.content}\n\`\`\``;
		case AttachmentType.LEGACY_CONTEXT:
			return `\n\n${extra.content}`;
		case AttachmentType.MCP_PROMPT:
			return `\n\n${extra.content}`;
		case AttachmentType.MCP_RESOURCE:
			return `\n\nResource ${extra.uri}:\n${extra.content}`;
		default:
			/*
			 * Images, audio and video are not sent: the bridge has no path
			 * for them yet, and a base64 part would cost more than it says.
			 */
			return '';
	}
}

/**
 * The `provider = key` lines of the Provider API keys setting. The provider
 * name is the one of the catalogue, lower case; a blank row and a row that
 * starts with '#' are left out.
 *
 * @param lines one `provider = key` a line
 */
export function parseProviderKeys(lines: string): Record<string, string> {
	const keys: Record<string, string> = {};

	for (const line of lines.split('\n')) {
		const row = line.trim();

		/* A blank row and a comment are not a key. */
		if (!row || row.startsWith('#')) continue;

		const at = row.indexOf('=');

		if (at <= 0) continue;

		const name = row.slice(0, at).trim().toLowerCase();
		const value = row.slice(at + 1).trim();

		if (name && value) keys[name] = value;
	}

	return keys;
}

/**
 * The prompt of a turn: the text of the last user message and the content of
 * its text attachments. fyai keeps the earlier turns of the session.
 */
export function buildFyaiPrompt(messages: DatabaseMessage[]): string | null {
	for (let i = messages.length - 1; i >= 0; i--) {
		const message = messages[i];

		if (message.role !== 'user') continue;

		const text = messageText(message.content).trim();

		if (!text) return null;

		const extras = (message.extra ?? []).map(extraText).join('');

		return text + extras;
	}

	return null;
}
