// SPDX-License-Identifier: MIT
import { type ChildProcess, spawn } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';

const BRIDGE = join(__dirname, '../../server/bridge.mjs');
const TOKEN = 'test-token';

let scratch: string;
let child: ChildProcess;
let base: string;

/* The bridge runs no fyai here: /bin/true answers the catalogue with nothing. */
const args = (extra: string[] = []) => [BRIDGE, '--bin', '/bin/true', '--cwd', scratch, ...extra];

beforeAll(async () => {
	scratch = mkdtempSync(join(tmpdir(), 'fyai-bridge-access-'));
	child = spawn(process.execPath, args(['--port', '0', '--token', TOKEN]), {
		stdio: ['pipe', 'pipe', 'pipe']
	});

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

const status = async (path: string, headers: Record<string, string> = {}) =>
	(await fetch(base + path, { headers, redirect: 'manual' })).status;

describe('the bridge access rules', () => {
	it('refuses the API without the token and tells the page nothing about the project', async () => {
		expect(await status('/props')).toBe(401);
		expect(await status('/v1/models')).toBe(401);
		expect(await status('/api/fyai/commands')).toBe(401);
		expect(await (await fetch(`${base}/api/fyai/info`)).json()).toEqual({
			authenticated: false,
			backend: 'fyai',
			protocol: 1
		});
	});

	it('answers the API with the token as a header or a cookie', async () => {
		expect(await status('/props', { 'x-fyai-token': TOKEN })).toBe(200);
		expect(await status('/props', { cookie: `fyai_bridge=${TOKEN}` })).toBe(200);
		expect(await status('/props', { 'x-fyai-token': 'wrong' })).toBe(401);
	});

	it('turns the token in a link into a cookie and goes on to the page', async () => {
		const res = await fetch(`${base}/api/fyai/login?token=${TOKEN}&next=//evil.example`, {
			redirect: 'manual'
		});

		expect(res.status).toBe(302);
		expect(res.headers.get('location')).toBe('/');
		expect(res.headers.get('set-cookie')).toContain('HttpOnly');
		expect(await status('/api/fyai/login?token=wrong')).toBe(401);
	});

	it('refuses another origin even with the token', async () => {
		const headers = { origin: 'http://evil.example', 'x-fyai-token': TOKEN };

		expect(await status('/props', headers)).toBe(403);

		const preflight = await fetch(`${base}/api/fyai/chat`, { headers, method: 'OPTIONS' });

		expect(preflight.status).toBe(403);
		expect(preflight.headers.get('access-control-allow-origin')).toBeNull();
	});

	it('refuses a host name that is not loopback', async () => {
		/* fetch cannot set Host: this goes through the socket directly. */
		const { request } = await import('node:http');
		const port = new URL(base).port;
		const code = await new Promise<number>((resolve, reject) => {
			const req = request(
				{ headers: { host: 'rebind.example', 'x-fyai-token': TOKEN }, path: '/props', port },
				(res) => {
					res.resume();
					resolve(res.statusCode ?? 0);
				}
			);

			req.on('error', reject);
			req.end();
		});

		expect(code).toBe(403);
	});

	it('serves the page files without a token', async () => {
		expect([200, 503]).toContain(await status('/'));
	});

	it('answers no wildcard CORS header on any answer', async () => {
		const res = await fetch(`${base}/props`, { headers: { 'x-fyai-token': TOKEN } });

		expect(res.headers.get('access-control-allow-origin')).toBeNull();
	});
});
