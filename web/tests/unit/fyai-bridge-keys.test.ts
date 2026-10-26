// SPDX-License-Identifier: MIT
import { type ChildProcess, spawn } from 'node:child_process';
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';

const BRIDGE = join(__dirname, '../../server/bridge.mjs');
const FAKE = join(__dirname, '../fixtures/fake-fyai.mjs');
const TOKEN = 'keys-token';
const SECRET = 'sk-test-0123456789';

let scratch: string;
let state: string;
let child: ChildProcess;
let base: string;

beforeAll(async () => {
	scratch = mkdtempSync(join(tmpdir(), 'fyai-bridge-keys-'));
	state = join(scratch, 'state.json');
	writeFileSync(state, JSON.stringify({ branches: {} }));
	chmodSync(FAKE, 0o755);
	child = spawn(
		process.execPath,
		[BRIDGE, '--bin', FAKE, '--cwd', scratch, '--port', '0', '--token', TOKEN],
		{
			env: { ...process.env, FAKE_FYAI_STATE: state, OPENAI_API_KEY: '', XDG_CONFIG_HOME: scratch },
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
	fetch(`${base}/api/fyai/keys${path}`, {
		...init,
		headers: { 'content-type': 'application/json', 'x-fyai-token': TOKEN }
	});

describe('the provider keys of the bridge', () => {
	it('lists the providers with no key set', async () => {
		const body = await (await call('')).json();

		expect(body.keys).toEqual([
			{ env: false, provider: 'anthropic', stored: false },
			{ env: false, provider: 'openai', stored: false }
		]);
	});

	it('stores a key in the secret store and never returns it', async () => {
		const put = await call('/anthropic', { body: JSON.stringify({ key: SECRET }), method: 'PUT' });

		expect(put.status).toBe(200);
		expect(JSON.parse(readFileSync(state, 'utf8')).secrets['api-key/anthropic']).toBe(SECRET);

		const text = await (await call('')).text();

		expect(text).not.toContain(SECRET);
		expect(JSON.parse(text).keys[0]).toEqual({ env: false, provider: 'anthropic', stored: true });
	});

	it('removes a key', async () => {
		expect((await call('/anthropic', { method: 'DELETE' })).status).toBe(200);

		const body = await (await call('')).json();

		expect(body.keys[0].stored).toBe(false);
	});

	it('refuses an unknown provider, an empty key and a key of two lines', async () => {
		const put = (name: string, key: string) =>
			call(`/${name}`, { body: JSON.stringify({ key }), method: 'PUT' });

		expect((await put('nobody', SECRET)).status).toBe(404);
		expect((await put('openai', '  ')).status).toBe(400);
		expect((await put('openai', 'a\nb')).status).toBe(400);
		expect(JSON.parse(readFileSync(state, 'utf8')).secrets ?? {}).toEqual({});
	});

	it('needs the token', async () => {
		const res = await fetch(`${base}/api/fyai/keys`);

		expect(res.status).toBe(401);
	});
});
