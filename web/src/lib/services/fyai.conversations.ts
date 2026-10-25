// SPDX-License-Identifier: MIT
/**
 * The conversations of fyai. A conversation is the branch `sdk/ID` of the
 * project, and the page keeps a copy of it in its own database. The bridge
 * lists, reads, renames and deletes the branches; this module calls it and
 * turns the stored messages of a branch into the rows that the page shows.
 */

import { AttachmentType, MessageRole } from '$lib/enums';
import { fyaiStoredToolView } from '$lib/services/fyai.tools';
import type { DatabaseConversation, DatabaseMessage, DatabaseMessageExtra } from '$lib/types';

export interface FyaiConversationSummary {
	id: string;
	model: string;
	/** The description of the branch, which the page sets as the title. */
	name: string;
	turns: number;
	/** Milliseconds since the epoch. */
	updated: number;
}

/** The ID of the session of a conversation: the bytes that a branch name can hold. */
export function fyaiSessionId(conversationId: string): string {
	return (
		String(conversationId ?? '')
			.replace(/[^0-9A-Za-z_-]/g, '_')
			.slice(0, 64) || ''
	);
}

const TITLE_MAX = 80;

async function request(path: string, init?: RequestInit): Promise<Response> {
	const response = await fetch(`/api/fyai/conversations${path}`, init);

	if (response.ok) return response;

	let message = `the bridge answered ${response.status}`;

	try {
		const body = (await response.json()) as { error?: { message?: string } };

		if (body?.error?.message) message = body.error.message;
	} catch {
		/* A body that is not JSON leaves the status as the reason. */
	}

	throw new Error(message);
}

export async function listFyaiConversations(): Promise<FyaiConversationSummary[]> {
	const body = (await (await request('')).json()) as {
		conversations?: FyaiConversationSummary[];
	};

	return Array.isArray(body.conversations) ? body.conversations : [];
}

export async function readFyaiMessages(id: string): Promise<unknown[]> {
	const body = (await (await request(`/${encodeURIComponent(id)}/messages`)).json()) as {
		messages?: unknown[];
	};

	return Array.isArray(body.messages) ? body.messages : [];
}

export async function renameFyaiConversation(id: string, name: string): Promise<void> {
	await request(`/${encodeURIComponent(id)}`, {
		body: JSON.stringify({ name }),
		headers: { 'content-type': 'application/json' },
		method: 'PATCH'
	});
}

export async function deleteFyaiConversation(id: string): Promise<void> {
	await request(`/${encodeURIComponent(id)}`, { method: 'DELETE' });
}

/** The text of the content of a stored message: a string, or the text parts of a list. */
function contentText(content: unknown): string {
	if (typeof content === 'string') return content;

	if (!Array.isArray(content)) return '';

	return content
		.map((part) =>
			part && typeof part === 'object' && typeof (part as { text?: unknown }).text === 'string'
				? (part as { text: string }).text
				: ''
		)
		.join('');
}

/**
 * The bytes of the `data` of a stored image, which the JSON of `history` writes
 * as text: a byte below 0x80 is that character and any other byte is the lone
 * surrogate U+DC00 plus the byte. Null for a string that is not that.
 */
export function storedImageBytes(data: string): Uint8Array | null {
	const bytes = new Uint8Array(data.length);

	for (let i = 0; i < data.length; i++) {
		const unit = data.charCodeAt(i);

		if (unit < 0x80) bytes[i] = unit;
		else if (unit >= 0xdc80 && unit <= 0xdcff) bytes[i] = unit - 0xdc00;
		else return null;
	}

	return bytes;
}

/** The image parts of a stored content as the attachments of a page message. */
function imageExtras(content: unknown): DatabaseMessageExtra[] {
	if (!Array.isArray(content)) return [];

	const extras: DatabaseMessageExtra[] = [];

	for (const part of content as Array<Record<string, unknown>>) {
		if (part?.type !== 'image' || typeof part.data !== 'string') continue;

		const bytes = storedImageBytes(part.data);

		if (!bytes || !bytes.length || typeof part.media_type !== 'string') continue;

		let binary = '';

		for (let i = 0; i < bytes.length; i += 0x8000)
			binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));

		extras.push({
			base64Url: `data:${part.media_type};base64,${btoa(binary)}`,
			name: typeof part.name === 'string' && part.name ? part.name : 'image',
			size: bytes.length,
			type: AttachmentType.IMAGE
		});
	}

	return extras;
}

/** The title of a conversation that has none: the first line of its first message. */
function titleOf(messages: unknown[]): string {
	for (const message of messages) {
		const item = message as { content?: unknown; role?: string };

		if (item?.role !== MessageRole.USER) continue;

		const line = contentText(item.content)
			.split('\n')
			.find((l) => l.trim().length > 0);

		if (line) return line.trim().slice(0, TITLE_MAX);
	}

	return 'Conversation';
}

/**
 * The conversation and message rows for the stored messages of a branch. The
 * stored form is the canonical one of fyai: a message of a role, a
 * `function_call` and its `function_call_output`. The rows are the chain that
 * the page keeps: a root, then each message under the one before it. A call
 * belongs to the assistant message before it, or to an empty one when none
 * comes first, and its result is a message of the tool role. Anything that the
 * page has no row for, such as a system prompt, is left out.
 *
 * @param summary the branch, for its ID, title and time
 * @param stored the messages of `fyai history --output json`
 * @param newId makes the ID of a row
 */
export function fyaiConversationRows(
	summary: FyaiConversationSummary,
	stored: unknown[],
	newId: () => string
): { conv: DatabaseConversation; messages: DatabaseMessage[] } {
	const convId = summary.id;
	const rows: DatabaseMessage[] = [];
	/* A row is dated a millisecond after the one before it, so the order is kept. */
	const start = summary.updated - stored.length - 1;
	const add = (fields: Partial<DatabaseMessage> & Pick<DatabaseMessage, 'role'>) => {
		const parent = rows.at(-1);
		const row: DatabaseMessage = {
			children: [],
			content: '',
			convId,
			id: newId(),
			parent: parent?.id ?? null,
			timestamp: start + rows.length,
			toolCalls: '',
			type: 'text',
			...fields
		};

		parent?.children.push(row.id);
		rows.push(row);

		return row;
	};

	add({ role: MessageRole.SYSTEM, type: 'root' });

	let openAssistant: DatabaseMessage | null = null;

	for (const item of stored as Array<Record<string, unknown>>) {
		if (!item || typeof item !== 'object') continue;

		if (item.type === 'function_call') {
			const view = fyaiStoredToolView(String(item.name ?? ''), String(item.arguments ?? ''));
			const call = {
				function: { arguments: view.arguments, name: view.name },
				id: String(item.call_id ?? ''),
				type: 'function'
			};
			const target: DatabaseMessage = openAssistant ?? add({ role: MessageRole.ASSISTANT });
			const calls = target.toolCalls ? (JSON.parse(target.toolCalls) as unknown[]) : [];

			calls.push(call);
			target.toolCalls = JSON.stringify(calls);
			openAssistant = target;

			continue;
		}

		if (item.type === 'function_call_output') {
			add({
				content: typeof item.output === 'string' ? item.output : JSON.stringify(item.output ?? ''),
				role: MessageRole.TOOL,
				toolCallId: String(item.call_id ?? '')
			});

			continue;
		}

		if (item.role === MessageRole.USER) {
			const extra = imageExtras(item.content);

			add({
				content: contentText(item.content),
				role: MessageRole.USER,
				...(extra.length ? { extra } : {})
			});
			openAssistant = null;
		} else if (item.role === MessageRole.ASSISTANT) {
			openAssistant = add({ content: contentText(item.content), role: MessageRole.ASSISTANT });
		}
	}

	return {
		conv: {
			currNode: rows.at(-1)?.id ?? '',
			id: convId,
			lastModified: summary.updated,
			name: summary.name || titleOf(stored)
		},
		messages: rows
	};
}
