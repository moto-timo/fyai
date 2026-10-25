// SPDX-License-Identifier: MIT
import { DatabaseService } from '$lib/services/database.service';
import type { DatabaseConversation, DatabaseMessage } from '$lib/types';
import { beforeAll, describe, expect, it } from 'vitest';

/* The test environment has no IndexedDB, so a table that works is a table in memory. */
beforeAll(async () => {
	expect((globalThis as { indexedDB?: unknown }).indexedDB).toBeUndefined();
	await DatabaseService.useMemory();
});

const message = (id: string, convId: string, parent: string | null): DatabaseMessage =>
	({
		children: [],
		content: id,
		convId,
		id,
		parent,
		role: 'user',
		timestamp: 1,
		toolCalls: '',
		type: 'text'
	}) as unknown as DatabaseMessage;

describe('DatabaseService in memory', () => {
	it('creates a conversation under the ID that the server gave', async () => {
		const conv = await DatabaseService.createConversation(
			'Chat',
			{},
			'session/20260101T000000.000001'
		);

		expect(conv.id).toBe('session/20260101T000000.000001');
		expect(await DatabaseService.getConversation(conv.id)).toMatchObject({ name: 'Chat' });
	});

	it('replaces a conversation and its messages as the server sent them', async () => {
		const conv = {
			currNode: 'b',
			id: 'main',
			lastModified: 5,
			name: 'Stub'
		} as DatabaseConversation;

		await DatabaseService.replaceConversation({ conv: { ...conv, currNode: '' }, messages: [] });
		await DatabaseService.replaceConversation({
			conv,
			messages: [message('a', 'main', null), message('b', 'main', 'a')]
		});

		expect((await DatabaseService.getConversationMessages('main')).map((m) => m.id)).toEqual([
			'a',
			'b'
		]);

		await DatabaseService.replaceConversation({ conv, messages: [message('c', 'main', null)] });

		expect((await DatabaseService.getConversationMessages('main')).map((m) => m.id)).toEqual(['c']);
	});

	it('deletes a conversation with its messages', async () => {
		await DatabaseService.deleteConversation('main');

		expect(await DatabaseService.getConversation('main')).toBeUndefined();
		expect(await DatabaseService.getConversationMessages('main')).toEqual([]);
	});
});
