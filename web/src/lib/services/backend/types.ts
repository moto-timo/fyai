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
 * `ok` and `error` end the turn. `skip` leaves it to the generic path, as
 * when the last message has nothing the backend can send.
 */
export type BackendTurnResult = 'error' | 'ok' | 'skip';

export interface Backend {
	capabilities: BackendCapabilities;
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
