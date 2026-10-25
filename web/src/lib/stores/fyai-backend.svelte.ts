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
import { settingsStore } from './settings/index.svelte';
import { MessageRole } from '$lib/enums';
import {
	type Backend,
	type BackendCommand,
	type BackendTurnRequest,
	type BackendTurnResult,
	registerBackend
} from '$lib/services/backend';
import { FYAI_BRIDGE_KIND } from '$lib/services/backend/kinds';
import { buildFyaiPrompt, parseProviderKeys, streamFyaiTurn } from '$lib/services/fyai.service';
import { FyaiTurnAssembler } from '$lib/services/fyai.turn';
import type { ChatMessageTimings } from '$lib/types';
import { apiFetch } from '$lib/utils/api-fetch';

export { FYAI_BRIDGE_KIND };

const TITLE_MAX = 80;

async function runTurn(request: BackendTurnRequest): Promise<BackendTurnResult> {
	const prompt = buildFyaiPrompt(request.allMessages);
	const { callbacks, convId } = request;

	if (!prompt) return 'skip';

	/*
	 * The session ID is the conversation ID. fyai stores the turns, so a
	 * turn sends only what the user typed since the last one. A conversation
	 * with no answer yet has no session, unless an earlier turn failed after
	 * it started one: the bridge asks fyai for the other mode then.
	 */
	const fresh = !request.allMessages.some((m) => m.role === MessageRole.ASSISTANT);

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
				undefined,
				timings,
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
		onText: (text) => callbacks.onChunk?.(text),
		onTimings: (value) => {
			timings = value;
			callbacks.onTimings?.(value);
		}
	});

	try {
		await streamFyaiTurn(
			{
				apiKey: settingsStore.config.apiKey?.toString().trim() ?? '',
				conversationId: convId,
				fresh,
				model: request.model,
				prompt,
				providerKeys: parseProviderKeys(settingsStore.config.providerApiKeys?.toString() ?? '')
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
		sampling: false
	},
	/*
	 * Each conversation is its own fyai session, so a new conversation is what
	 * clears the model context. The line is not stored.
	 */
	handleLine: async (line) => {
		if (line.trim() !== '/clear') return false;

		await conversationsStore.createConversation();

		return true;
	},
	kind: FYAI_BRIDGE_KIND,
	loadCommands,
	probe: async () => {
		const info = await apiFetch<{ backend?: string }>('/api/fyai/info');

		return info.backend === 'fyai';
	},
	runTurn,
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
