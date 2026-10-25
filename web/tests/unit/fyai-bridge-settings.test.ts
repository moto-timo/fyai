// SPDX-License-Identifier: MIT
import { type ChildProcess, spawn } from 'node:child_process';
import { chmodSync, existsSync, mkdtempSync, readFileSync, rmSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';

const BRIDGE = join(__dirname, '../../server/bridge.mjs');
const FAKE = join(__dirname, '../fixtures/fake-fyai.mjs');
const TOKEN = 'settings-token';

let scratch: string;
let child: ChildProcess;
let base: string;

beforeAll(async () => {
	scratch = mkdtempSync(join(tmpdir(), 'fyai-bridge-settings-'));
	chmodSync(FAKE, 0o755);
	child = spawn(
		process.execPath,
		[BRIDGE, '--bin', FAKE, '--cwd', scratch, '--port', '0', '--token', TOKEN],
		{
			env: { ...process.env, XDG_CONFIG_HOME: join(scratch, 'config') },
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

const call = (init: RequestInit = {}) =>
	fetch(`${base}/api/fyai/settings`, {
		...init,
		headers: { 'content-type': 'application/json', 'x-fyai-token': TOKEN }
	});

describe('the settings of the bridge', () => {
	it('has none before the page writes any', async () => {
		expect(await (await call()).json()).toEqual({ settings: null });
	});

	it('keeps what the page writes and drops the keys', async () => {
		const body = {
			config: { apiKey: 'sk-secret', providerApiKeys: 'a = b', theme: 'dark', topK: 40 },
			userOverrides: ['theme', 'apiKey']
		};

		expect((await call({ body: JSON.stringify(body), method: 'PUT' })).status).toBe(200);
		expect(await (await call()).json()).toEqual({
			settings: { config: { theme: 'dark', topK: 40 }, userOverrides: ['theme'] }
		});

		const file = join(scratch, 'config', 'fyai', 'web-settings.json');

		expect(existsSync(file)).toBe(true);
		expect(readFileSync(file, 'utf8')).not.toContain('sk-secret');
		expect(statSync(file).mode & 0o777).toBe(0o600);
	});

	it('refuses a body with no config', async () => {
		expect((await call({ body: '{}', method: 'PUT' })).status).toBe(400);
		expect((await call({ body: 'x', method: 'PUT' })).status).toBe(400);
	});

	it('allows no other method and needs the token', async () => {
		expect((await call({ method: 'DELETE' })).status).toBe(405);
		expect((await fetch(`${base}/api/fyai/settings`)).status).toBe(401);
	});
});
