// SPDX-License-Identifier: MIT
/**
 * The provider keys of fyai. The bridge stores a key in the secret store of
 * fyai and says only whether one is set: no call returns a value.
 */

import { apiFetch } from '$lib/utils/api-fetch';

export interface ProviderKeyStatus {
	/** The environment of the bridge holds a key, which fyai reads first. */
	env: boolean;
	provider: string;
	/** The secret store of fyai holds a key. */
	stored: boolean;
}

const route = (provider: string) => `/api/fyai/keys/${encodeURIComponent(provider)}`;

export const fyaiKeys = {
	async list(): Promise<ProviderKeyStatus[]> {
		const body = await apiFetch<{ keys: ProviderKeyStatus[] }>('/api/fyai/keys');

		return body.keys;
	},
	async remove(provider: string): Promise<void> {
		await apiFetch(route(provider), { method: 'DELETE' });
	},
	async set(provider: string, key: string): Promise<void> {
		await apiFetch(route(provider), { body: JSON.stringify({ key }), method: 'PUT' });
	}
};
