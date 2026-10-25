// SPDX-License-Identifier: MIT
import type { Backend } from '$lib/services/backend';
import { beforeEach, describe, expect, it, vi } from 'vitest';

type Module = typeof import('$lib/services/backend');

let backends: Module;

/* The registry is module state: each test starts from a fresh one. */
beforeEach(async () => {
	vi.resetModules();
	backends = await import('$lib/services/backend');
});

const caps = {
	agenticLoop: false,
	browserMcp: false,
	browserTools: false,
	modelManager: false,
	sampling: false
};

function backend(kind: string, probe?: () => Promise<boolean>): Backend {
	return { capabilities: caps, kind, probe };
}

describe('detectBackend', () => {
	it('falls back to llama-server when no probe answers', async () => {
		backends.registerBackend(backend('never', async () => false));

		expect((await backends.detectBackend()).kind).toBe('llama');
	});

	it('takes the first backend whose probe answers true', async () => {
		backends.registerBackend(backend('first', async () => true));
		backends.registerBackend(backend('second', async () => true));

		expect((await backends.detectBackend()).kind).toBe('first');
	});

	it('treats a probe that throws as no match', async () => {
		backends.registerBackend(backend('first', async () => false));
		backends.registerBackend(backend('broken', async () => Promise.reject(new Error('down'))));
		backends.registerBackend(backend('second', async () => true));

		expect((await backends.detectBackend()).kind).toBe('second');
	});

	it('uses a forced kind without asking the probes', async () => {
		let asked = false;

		backends.registerBackend(
			backend('forced', async () => {
				asked = true;

				return false;
			})
		);

		expect((await backends.detectBackend('forced')).kind).toBe('forced');
		expect(asked).toBe(false);
	});

	it('ignores a forced kind that is not registered', async () => {
		expect((await backends.detectBackend('missing')).kind).not.toBe('missing');
	});

	it('replaces a backend registered again under the same kind', async () => {
		backends.registerBackend(backend('again', async () => false));
		backends.registerBackend(backend('again', async () => true));

		expect((await backends.detectBackend()).kind).toBe('again');
		expect((await backends.detectBackend('again')).capabilities.sampling).toBe(false);
	});
});
