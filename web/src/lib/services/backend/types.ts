// SPDX-License-Identifier: MIT
import type { ChatStreamCallbacks, DatabaseMessage } from '$lib/types';

/**
 * The parts of the page that depend on what the server behind it can do.
 * A backend states each one; the page hides a part its backend lacks and
 * keeps it, unchanged, for a backend that has it.
 */
export interface BackendCapabilities {
	/** The page runs the multi-turn tool loop itself. */
	agenticLoop: boolean;
	/** The page connects to MCP servers from the browser. */
	browserMcp: boolean;
	/** The JavaScript sandbox and the other tools that run in the browser. */
	browserTools: boolean;
	/** Hugging Face discovery and the model manager. */
	modelManager: boolean;
	/** Sampling, penalties and their sync with the server defaults. */
	sampling: boolean;
	/**
	 * The server keeps the conversations. The page holds them in memory for
	 * the session and loads them from the server, so the browser keeps none.
	 */
	serverConversations: boolean;
}

/** The arguments of one turn that a backend runs in place of the page. */
export interface BackendTurnRequest {
	allMessages: DatabaseMessage[];
	assistantMessage: DatabaseMessage;
	callbacks: ChatStreamCallbacks;
	convId: string;
	model: string | null;
	signal: AbortSignal;
}

/**
 * `ok` and `error` end the turn. `skip` leaves it to the generic request
 * paths when the backend has the `agenticLoop` capability, and is an error
 * for the user when it has not: the last message had nothing to send.
 */
export type BackendTurnResult = 'error' | 'ok' | 'skip';

/** A slash command that the server runs, shown in the `/` picker. */
export interface BackendCommand {
	aliases: string[];
	description: string;
	name: string;
	title: string;
}

export interface Backend {
	capabilities: BackendCapabilities;
	/**
	 * A title for a new conversation from its first message, or null to let
	 * the page ask the model. A backend with no title function uses the model.
	 */
	titleFor?: (firstMessage: string) => string | null;
	/** Loads the slash commands of the server, for the `/` picker. */
	loadCommands?: () => Promise<BackendCommand[]>;
	/**
	 * Takes a line the user sent before the page stores it. Resolves true when
	 * the backend handled the line and nothing is sent.
	 */
	handleLine?: (line: string) => Promise<boolean>;
	/**
	 * Loads the list of conversations that the server holds into the page. It
	 * runs before the page shows its list, and the messages of a conversation
	 * come with `hydrateConversation`.
	 */
	syncConversations?: () => Promise<void>;
	/**
	 * Loads the messages of a conversation of the server into the page, when
	 * the page has not read them yet. It runs before a conversation opens.
	 */
	hydrateConversation?: (id: string) => Promise<void>;
	/**
	 * The ID of a new conversation. A server that names its conversations says
	 * the name here; a backend with no such function lets the page make one.
	 */
	newConversationId?: () => Promise<string>;
	/** Tells the server that the page renamed a conversation. */
	renameConversation?: (id: string, name: string) => Promise<void>;
	/** Tells the server that the page deleted a conversation. */
	deleteConversation?: (id: string) => Promise<void>;
	/** Stable name, used by `backendIs()` and the forced-backend setting. */
	kind: string;
	/**
	 * Tells whether the server behind the page is this backend. A backend
	 * with no probe is the fallback and matches last.
	 */
	probe?: () => Promise<boolean>;
	/** Runs one turn. A backend that has none uses the generic request path. */
	runTurn?: (request: BackendTurnRequest) => Promise<BackendTurnResult>;
}
