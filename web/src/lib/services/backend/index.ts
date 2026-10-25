// SPDX-License-Identifier: MIT
import { llamaBackend } from './llama.backend';
import type { Backend } from './types';

export type {
	Backend,
	BackendCapabilities,
	BackendCommand,
	BackendSettings,
	BackendTurnRequest,
	BackendTurnResult,
	PersistedSettings
} from './types';
export { llamaBackend };

const registry: Backend[] = [];

/**
 * Adds a backend. A later registration of the same kind replaces the earlier
 * one. Backends with a probe are asked in registration order.
 */
export function registerBackend(backend: Backend): void {
	const at = registry.findIndex((b) => b.kind === backend.kind);

	if (at >= 0) registry[at] = backend;
	else registry.push(backend);
}

export function findBackend(kind: string): Backend | undefined {
	return registry.find((b) => b.kind === kind);
}

/**
 * Picks the backend of the server. A forced kind wins when it is registered.
 * Otherwise the first backend whose probe answers true is used, and a probe
 * that throws counts as false. With no match the fallback is llama-server.
 */
export async function detectBackend(forced?: string | null): Promise<Backend> {
	const wanted = forced ? findBackend(forced) : undefined;

	if (wanted) return wanted;

	for (const backend of registry) {
		if (!backend.probe) continue;

		try {
			if (await backend.probe()) return backend;
		} catch {
			// a server that cannot answer is not this backend
		}
	}

	return llamaBackend;
}

registerBackend(llamaBackend);
