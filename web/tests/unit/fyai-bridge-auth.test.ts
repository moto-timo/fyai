// SPDX-License-Identifier: MIT
import {
	cookieValue,
	corsHeaders,
	hostAllowed,
	isLoopbackHost,
	makeToken,
	originAllowed,
	safeNext,
	tokenCookie,
	tokenFromHeaders,
	tokensEqual
} from '../../server/auth.mjs';
import { describe, expect, it } from 'vitest';

describe('tokens', () => {
	it('makes a different 64 digit token each time', () => {
		expect(makeToken()).toMatch(/^[0-9a-f]{64}$/);
		expect(makeToken()).not.toBe(makeToken());
	});

	it('compares tokens', () => {
		expect(tokensEqual('abc', 'abc')).toBe(true);
		expect(tokensEqual('abd', 'abc')).toBe(false);
		expect(tokensEqual('ab', 'abc')).toBe(false);
		expect(tokensEqual('', '')).toBe(false);
		expect(tokensEqual(undefined as never, 'abc')).toBe(false);
	});

	it('reads the token from the header before the cookie', () => {
		expect(tokenFromHeaders({ cookie: 'fyai_bridge=c', 'x-fyai-token': 'h' })).toBe('h');
		expect(tokenFromHeaders({ cookie: 'a=1; fyai_bridge=c' })).toBe('c');
		expect(tokenFromHeaders({})).toBe('');
	});

	it('finds a cookie by its whole name', () => {
		expect(cookieValue('xfyai_bridge=bad; fyai_bridge=good', 'fyai_bridge')).toBe('good');
	});

	it('sets a cookie that a script cannot read and another site does not send', () => {
		expect(tokenCookie('t')).toBe('fyai_bridge=t; HttpOnly; SameSite=Strict; Path=/');
	});
});

describe('hosts and origins', () => {
	it('knows the loopback names', () => {
		for (const host of ['localhost', 'localhost:9331', '127.0.0.1:1', '[::1]:80', '::1']) {
			expect(isLoopbackHost(host)).toBe(true);
		}

		for (const host of ['example.com', '10.0.0.1', '0.0.0.0', '', undefined]) {
			expect(isLoopbackHost(host)).toBe(false);
		}
	});

	it('lets a request with no origin through', () => {
		expect(originAllowed(undefined, '127.0.0.1:9331')).toBe(true);
	});

	it('lets the page of the bridge through and nothing else', () => {
		expect(originAllowed('http://127.0.0.1:9331', '127.0.0.1:9331')).toBe(true);
		expect(originAllowed('http://evil.example', '127.0.0.1:9331')).toBe(false);
		expect(originAllowed('http://127.0.0.1:9332', '127.0.0.1:9331')).toBe(false);
		expect(originAllowed('null', '127.0.0.1:9331')).toBe(false);
	});

	it('lets a listed origin through', () => {
		expect(
			originAllowed('http://localhost:5173', '127.0.0.1:9331', ['http://localhost:5173'])
		).toBe(true);
	});

	it('answers only loopback names on a loopback bridge', () => {
		expect(hostAllowed('localhost:9331', '127.0.0.1')).toBe(true);
		expect(hostAllowed('rebind.example:9331', '127.0.0.1')).toBe(false);
		expect(hostAllowed('tunnel.example', '127.0.0.1', ['tunnel.example'])).toBe(true);
		expect(hostAllowed('any.example', '0.0.0.0')).toBe(true);
	});

	it('never answers with a wildcard', () => {
		const allowed = ['http://localhost:5173'];

		expect(corsHeaders('http://localhost:5173', '127.0.0.1:9331', allowed)).toMatchObject({
			'access-control-allow-credentials': 'true',
			'access-control-allow-origin': 'http://localhost:5173'
		});
		expect(corsHeaders('http://evil.example', '127.0.0.1:9331', allowed)).toEqual({});
		expect(corsHeaders(undefined, '127.0.0.1:9331', allowed)).toEqual({});
		expect(
			corsHeaders('http://127.0.0.1:9331', '127.0.0.1:9331', ['http://127.0.0.1:9331'])
		).toEqual({});
	});
});

describe('safeNext', () => {
	it('keeps a path of the bridge', () => {
		expect(safeNext('/chat/1')).toBe('/chat/1');
	});

	it('sends anything else to the root', () => {
		for (const next of ['//evil.com', 'http://evil.com', '/\\evil.com', '', undefined, null]) {
			expect(safeNext(next)).toBe('/');
		}
	});
});
