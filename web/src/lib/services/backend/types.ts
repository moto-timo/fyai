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
