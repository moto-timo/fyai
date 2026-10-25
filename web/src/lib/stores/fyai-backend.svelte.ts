// SPDX-License-Identifier: MIT
/**
 * The fyai backend: the page talks to the bridge that runs fyai.
 *
 * fyai keeps the conversation and runs the tool loop of the turn itself, so
 * one request is the whole turn: its assistant messages and tool results
 * arrive in the one stream. This module registers that behaviour with the
 * backend seam; it is a store because a command that selects a model moves
 * the model selection of the page.
 */

import { conversationsStore } from './conversations/index.svelte';
import { modelsStore } from './models/index.svelte';
import { MessageRole } from '$lib/enums';
import {
	type Backend,
	type BackendCommand,
	type BackendTurnRequest,
	type BackendTurnResult,
	registerBackend
} from '$lib/services/backend';
import { FYAI_BRIDGE_KIND } from '$lib/services/backend/kinds';
import { DatabaseService } from '$lib/services/database.service';
import {
	deleteFyaiConversation,
	fyaiConversationRows,
	listFyaiConversations,
	newFyaiConversationId,
	readFyaiMessages,
	renameFyaiConversation
} from '$lib/services/fyai.conversations';
import {
	buildFyaiPrompt,
	fyaiAnchor,
	fyaiImages,
	fyaiUnsupportedAttachments,
	streamFyaiTurn
} from '$lib/services/fyai.service';
import { fyaiSettings } from '$lib/services/fyai.settings';
import { FyaiTurnAssembler } from '$lib/services/fyai.turn';
import type { ChatMessageTimings } from '$lib/types';
import { uuid } from '$lib/utils';
import { apiFetch } from '$lib/utils/api-fetch';

export { FYAI_BRIDGE_KIND };

const TITLE_MAX = 80;

async function runTurn(request: BackendTurnRequest): Promise<BackendTurnResult> {
	const { callbacks, convId } = request;
	const images = fyaiImages(request.allMessages);
	const unsupported = fyaiUnsupportedAttachments(request.allMessages);

	if (unsupported.length) {
		callbacks.onError?.(
			new Error(
				`fyai takes images and text files, not audio or video: ${unsupported.join(', ')}. ` +
					'Remove the attachment and send the message again.'
			)
		);

		return 'error';
	}

	/* A message of images alone has no text and is still a prompt. */
	const prompt = buildFyaiPrompt(request.allMessages) ?? (images.length ? '' : null);

	if (prompt === null) return 'skip';

	/*
	 * The conversation ID is the name of the branch. fyai stores the
	 * exchanges, so a turn sends only what the user typed since the last one.
	 */
	hydrated.add(convId);

	let timings: ChatMessageTimings | undefined;
	let error = false;

	const assembler = new FyaiTurnAssembler({
		createMessage: () => callbacks.createAssistantMessage?.(),
		createToolResult: async (toolUseId: string, text: string) => {
			await callbacks.createToolResultMessage?.(toolUseId, text);
		},
		messageDone: async (message) => {
			await callbacks.onAssistantTurnComplete?.(
				message.content,
				message.reasoning || undefined,
				message.usage ?? timings,
				message.toolCalls.length
					? message.toolCalls.map((call) => ({
							function: { arguments: call.arguments, name: call.name },
							id: call.id,
							type: 'function' as const
						}))
					: undefined
			);
		},
		/*
		 * A command that selects a model must move the page's own selection
		 * too: every turn names the selected model to fyai, so a branch that
		 * /model changed would be overridden otherwise.
		 */
		onCommandModel: (model) => {
			modelsStore.selectModelByName(model);
			callbacks.onModel?.(model);
		},
		onError: (cause) => {
			error = true;
			callbacks.onError?.(cause);
		},
		/*
		 * The frame names the model of the provider, which the catalogue may
		 * spell another way. The model this turn asked for is the one the
		 * page knows, so a later turn and the picker agree with it.
		 */
		onModel: (model) => callbacks.onModel?.(request.model ?? model),
		onReasoning: (text) => callbacks.onReasoningChunk?.(text),
		onText: (text) => callbacks.onChunk?.(text),
		onTimings: (value) => {
			timings = value;
			callbacks.onTimings?.(value);
		}
	});

	try {
		await streamFyaiTurn(
			{
				anchor: fyaiAnchor(request.allMessages),
				conversationId: convId,
				images,
				model: request.model,
				prompt
			},
			(frame) => assembler.push(frame),
			request.signal
		);
	} catch (cause) {
		if (!assembler.hasFailed) {
			callbacks.onError?.(cause instanceof Error ? cause : new Error(String(cause)));
		}
	}

	if (await assembler.settled()) return 'error';

	return error ? 'error' : 'ok';
}

/*
 * The bridge reads the commands from `fyai schema commands`, so the picker
 * offers what that fyai supports and the page keeps no list of its own.
 */
async function loadCommands(): Promise<BackendCommand[]> {
	const res = await apiFetch<{ commands?: BackendCommand[] }>('/api/fyai/commands');

	return Array.isArray(res.commands) ? res.commands : [];
}

/*
 * The conversations whose messages the page holds. A conversation that the page
 * made or opened has them; one that only the list named does not.
 */
// eslint-disable-next-line svelte/prefer-svelte-reactivity -- bookkeeping that no view reads
const hydrated = new Set<string>();

/**
 * Load the list of branches of fyai as conversations of the page. fyai holds
 * the conversation, so the page keeps no record from an earlier visit: the
 * list replaces what is there, and the messages of a conversation come when it
 * is opened. A list that cannot be read changes nothing.
 */
async function syncConversations(): Promise<void> {
	const remote = await listFyaiConversations();
	const known = new Set((await DatabaseService.getAllConversations()).map((conv) => conv.id));

	for (const summary of remote) {
		if (known.has(summary.id)) continue;

		await DatabaseService.importConversations([
			{
				conv: {
					currNode: '',
					id: summary.id,
					lastModified: summary.updated,
					name: summary.name || summary.id
				},
				messages: []
			}
		]);
	}

	const present = new Set(remote.map((summary) => summary.id));

	/* One that has an exchange but no branch was deleted where fyai is. */
	for (const id of known) {
		if (present.has(id) || !hydrated.has(id)) continue;

		const messages = await DatabaseService.getConversationMessages(id);

		if (messages.some((m) => m.role === MessageRole.ASSISTANT))
			await DatabaseService.deleteConversation(id);
	}
}

/** Read the messages of a branch into the conversation of the page, once. */
async function hydrateConversation(id: string): Promise<void> {
	if (hydrated.has(id)) return;

	const summary = (await listFyaiConversations()).find((c) => c.id === id);

	if (!summary) return;

	const rows = fyaiConversationRows(summary, await readFyaiMessages(id), uuid);

	await DatabaseService.replaceConversation(rows);
	hydrated.add(id);
}

export const fyaiBackend: Backend = {
	/*
	 * fyai runs the tool loop, holds the tools and the MCP servers, picks the
	 * model from its catalogue and ignores the sampling fields of the page.
	 */
	capabilities: {
		agenticLoop: false,
		browserMcp: false,
		browserTools: false,
		modelManager: false,
		sampling: false,
		serverConversations: true
	},
	/*
	 * Each conversation is its own fyai session, so a new conversation is what
	 * clears the model context. The line is not stored.
	 */
	deleteConversation: (id) => deleteFyaiConversation(id),
	handleLine: async (line) => {
		if (line.trim() !== '/clear') return false;

		await conversationsStore.createConversation();

		return true;
	},
	hydrateConversation,
	kind: FYAI_BRIDGE_KIND,
	loadCommands,
	newConversationId: newFyaiConversationId,
	probe: async () => {
		const info = await apiFetch<{ backend?: string }>('/api/fyai/info');

		return info.backend === 'fyai';
	},
	renameConversation: (id, name) => renameFyaiConversation(id, name),
	runTurn,
	settings: fyaiSettings,
	syncConversations,
	/*
	 * The title comes from the message. A model request would start a session
	 * that no conversation reads.
	 */
	titleFor: (firstMessage) => {
		const line = firstMessage.split('\n').find((l) => l.trim().length > 0);

		return line ? line.trim().slice(0, TITLE_MAX) : null;
	}
};

registerBackend(fyaiBackend);
