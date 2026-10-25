// SPDX-License-Identifier: MIT
import { forcedBackend } from '$lib/services/backend/forced';
import { describe, expect, it } from 'vitest';

const stored = (value: string | null) => (key: string) => (key === 'fyai-backend' ? value : null);

describe('forcedBackend', () => {
	it('detects the backend when nothing forces it', () => {
		expect(forcedBackend({})).toBeNull();
		expect(forcedBackend({ build: '', search: '', storage: stored(null) })).toBeNull();
	});

	it('takes the query parameter first, then the storage, then the build', () => {
		const all = { build: 'c', search: '?backend=a', storage: stored('b') };

		expect(forcedBackend(all)).toBe('a');
		expect(forcedBackend({ ...all, search: '' })).toBe('b');
		expect(forcedBackend({ ...all, search: '?other=1', storage: stored(null) })).toBe('c');
	});

	it('reads a query string with or without its question mark', () => {
		expect(forcedBackend({ search: 'backend=fyai-remote' })).toBe('fyai-remote');
	});

	it('goes on when the storage cannot be read', () => {
		const broken = () => {
			throw new Error('blocked');
		};

		expect(forcedBackend({ build: 'c', storage: broken })).toBe('c');
	});
});
