// SPDX-License-Identifier: MIT
/**
 * The settings of the page, kept by the bridge in a file of the user. The
 * bridge drops a key that it is sent: fyai holds its keys, never the page.
 */

import type { BackendSettings, PersistedSettings } from '$lib/services/backend';
import { apiFetch } from '$lib/utils/api-fetch';

export const fyaiSettings: BackendSettings = {
	async load(): Promise<PersistedSettings | null> {
		const body = await apiFetch<{ settings?: PersistedSettings | null }>('/api/fyai/settings');

		return body.settings ?? null;
	},
	async save(settings: PersistedSettings): Promise<void> {
		const response = await fetch('/api/fyai/settings', {
			body: JSON.stringify(settings),
			headers: { 'content-type': 'application/json' },
			method: 'PUT'
		});

		if (!response.ok) throw new Error(`the bridge answered ${response.status}`);
	}
};
