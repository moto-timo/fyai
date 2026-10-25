// SPDX-License-Identifier: MIT
/**
 * backendStore - The backend behind the page
 *
 * Holds which backend the server is and what it can do. Components and
 * stores ask `backendIs()` or `supports()` at the few places where the page
 * differs by backend, and never test a server name themselves.
 */

import {
	type Backend,
	type BackendCapabilities,
	detectBackend,
	llamaBackend
} from '$lib/services/backend';

class BackendStore {
	active = $state<Backend>(llamaBackend);
	private detecting: Promise<void> | null = null;

	get kind(): string {
		return this.active.kind;
	}

	/** Asks the registered backends once; a forced kind skips the probes. */
	detect(forced?: string | null): Promise<void> {
		this.detecting ??= detectBackend(forced).then((backend) => {
			this.active = backend;
		});

		return this.detecting;
	}

	is(kind: string): boolean {
		return this.active.kind === kind;
	}

	supports(capability: keyof BackendCapabilities): boolean {
		return this.active.capabilities[capability];
	}
}

export const backendStore = new BackendStore();

export const backendIs = (kind: string): boolean => backendStore.is(kind);
