// SPDX-License-Identifier: MIT
import { type ChildProcess, spawn } from 'node:child_process';
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';

const BRIDGE = join(__dirname, '../../server/bridge.mjs');
const FAKE = join(__dirname, '../fixtures/fake-fyai.mjs');
const TOKEN = 'conversations-token';
const MESSAGES = [
	{ content: 'Run ls', role: 'user' },
	{ arguments: '{"command":"ls"}', call_id: 'c1', name: 'shell', type: 'function_call' },
	{ call_id: 'c1', output: 'a.txt\n', type: 'function_call_output' }
];

let scratch: string;
let child: ChildProcess;
let base: string;

beforeAll(async () => {
	scratch = mkdtempSync(join(tmpdir(), 'fyai-bridge-conversations-'));
	chmodSync(FAKE, 0o755);
	writeFileSync(
		join(scratch, 'state.json'),
		JSON.stringify({
			branches: {
				'agent/other': { turns: 1, updated: 3000 },
				main: { turns: 0 },
				'sdk/env': { turns: 1, updated: 500 },
				'sdk/newer': {
					description: 'A title',
					messages: MESSAGES,
					model: 'm1',
					turns: 2,
					updated: 2000
				},
				'sdk/older': { turns: 2, updated: 1000 }
			}
		})
	);
	child = spawn(
		process.execPath,
		[BRIDGE, '--bin', FAKE, '--cwd', scratch, '--port', '0', '--token', TOKEN],
		{
			env: { ...process.env, FAKE_FYAI_STATE: join(scratch, 'state.json') },
			stdio: ['pipe', 'pipe', 'pipe']
		}
	);

	base = await new Promise<string>((resolve, reject) => {
		let seen = '';

		child.stderr!.setEncoding('utf8');
		child.stderr!.on('data', (chunk: string) => {
			seen += chunk;

			const found = /listening on (http:\/\/\S+)/.exec(seen);

			if (found) resolve(found[1]);
		});
		child.on('exit', (code) => reject(new Error(`the bridge exited with ${code}: ${seen}`)));
	});
});

afterAll(() => {
	child.kill('SIGTERM');
	rmSync(scratch, { force: true, recursive: true });
});

const call = (path: string, init: RequestInit = {}) =>
	fetch(`${base}/api/fyai/conversations${path}`, {
		...init,
		headers: { 'content-type': 'application/json', 'x-fyai-token': TOKEN }
	});

describe('the conversations of the bridge', () => {
	it('lists the branches of the page sessions, newest first', async () => {
		const body = await (await call('')).json();

		expect(body.conversations).toEqual([
			{ id: 'newer', model: 'm1', name: 'A title', turns: 2, updated: 2000 },
			{ id: 'older', model: '', name: '', turns: 2, updated: 1000 },
			{ id: 'env', model: '', name: '', turns: 1, updated: 500 }
		]);
	});

	it('reads the stored messages of a conversation', async () => {
		const body = await (await call('/newer/messages')).json();

		expect(body.messages).toEqual(MESSAGES);
	});

	it('keeps the token out of the environment of the programs it runs', async () => {
		const body = await (await call('/env/messages')).json();

		expect(body.messages).toEqual([{ content: 'unset', role: 'user' }]);
	});

	it('refuses an ID that cannot name a branch of the page', async () => {
		/* The name is made safe, so it can only name a branch below sdk/. */
		const res = await call('/..%2Fmain', { method: 'DELETE' });

		expect(res.status).toBe(404);
		expect((await (await call('')).json()).conversations).toHaveLength(3);
	});

	it('needs the token', async () => {
		const res = await fetch(`${base}/api/fyai/conversations`);

		expect(res.status).toBe(401);
	});

	it('renames a conversation through its description', async () => {
		const res = await call('/older', {
			body: JSON.stringify({ name: 'Renamed' }),
			method: 'PATCH'
		});

		expect(res.status).toBe(200);
		expect(
			(await (await call('')).json()).conversations.map((c: { name: string }) => c.name)
		).toEqual(['A title', 'Renamed', '']);
		expect((await call('/older', { body: '{}', method: 'PATCH' })).status).toBe(400);
		expect((await call('/missing', { body: '{"name":"x"}', method: 'PATCH' })).status).toBe(404);
	});

	it('deletes a conversation and no other branch', async () => {
		expect((await call('/older', { method: 'DELETE' })).status).toBe(200);
		expect((await call('/older', { method: 'DELETE' })).status).toBe(404);

		const ids = (await (await call('')).json()).conversations.map((c: { id: string }) => c.id);

		expect(ids).toEqual(['newer', 'env']);
	});

	it('allows no other method', async () => {
		expect((await call('', { method: 'DELETE' })).status).toBe(405);
		expect((await call('/newer/messages', { method: 'POST' })).status).toBe(405);
	});
});
