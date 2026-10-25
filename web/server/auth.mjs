// SPDX-License-Identifier: MIT
/*
 * The access decisions of the bridge, with no socket: the token, the origin
 * and the host of a request. The bridge runs fyai tools in a project, so a
 * request needs the token and a page of another origin never gets an answer
 * it can read. The test suite imports this module directly.
 */

import { randomBytes, timingSafeEqual } from 'node:crypto';

/** The cookie that carries the token for a browser. */
export const TOKEN_COOKIE = 'fyai_bridge';
/** The header that carries the token for a program. */
export const TOKEN_HEADER = 'x-fyai-token';
/** The path that turns a token in a link into the cookie. */
export const LOGIN_PATH = '/api/fyai/login';

/** A new token: 256 random bits. */
export function makeToken() {
	return randomBytes(32).toString('hex');
}

/** True when @host, with or without a port, is a loopback name or address. */
/**
 * @param {unknown} host
 * @returns {boolean}
 */
export function isLoopbackHost(host) {
	let name = String(host ?? '').toLowerCase();

	if (name.startsWith('[')) name = name.slice(1, name.indexOf(']'));
	/* A name with more than one colon is a bare IPv6 address and has no port. */
	else if (name.split(':').length === 2) name = name.slice(0, name.indexOf(':'));

	return name === 'localhost' || name === '::1' || /^127(\.\d{1,3}){3}$/.test(name);
}

/** The value of cookie @name in a Cookie header, or ''. */
/**
 * @param {unknown} header
 * @param {string} name
 * @returns {string}
 */
export function cookieValue(header, name) {
	for (const part of String(header ?? '').split(';')) {
		const at = part.indexOf('=');

		if (at > 0 && part.slice(0, at).trim() === name) return part.slice(at + 1).trim();
	}

	return '';
}

/** The token a request carries: the header first, then the cookie. */
/**
 * @param {Record<string, string | string[] | undefined>} headers
 * @returns {string}
 */
export function tokenFromHeaders(headers) {
	const given = headers[TOKEN_HEADER];

	if (typeof given === 'string' && given) return given;

	return cookieValue(headers.cookie, TOKEN_COOKIE);
}

/** True when @given is @expected. The comparison takes the same time for any input. */
/**
 * @param {unknown} given
 * @param {string} expected
 * @returns {boolean}
 */
export function tokensEqual(given, expected) {
	if (!expected || typeof given !== 'string') return false;

	const a = Buffer.from(given);
	const b = Buffer.from(expected);

	return a.length === b.length && timingSafeEqual(a, b);
}

/**
 * True when a request of @origin may be answered. A request with no Origin
 * header is not from a page of another site, so it passes. A page of the
 * bridge itself has an Origin whose host is the Host of the request. Any other
 * origin has to be listed.
 */
/**
 * @param {string | undefined} origin
 * @param {string} host
 * @param {string[]} [allowedOrigins]
 * @returns {boolean}
 */
export function originAllowed(origin, host, allowedOrigins = []) {
	if (!origin) return true;

	if (allowedOrigins.includes(origin)) return true;

	try {
		return new URL(origin).host === host;
	} catch {
		return false;
	}
}

/**
 * True when the Host header names this bridge. A bridge on a loopback address
 * answers only loopback names, which stops a page of another site from
 * reaching it through a name that it moved to 127.0.0.1 (DNS rebinding). A
 * bridge on another address answers any name; the token protects it.
 */
/**
 * @param {string} host
 * @param {string} bindHost
 * @param {string[]} [allowedHosts]
 * @returns {boolean}
 */
export function hostAllowed(host, bindHost, allowedHosts = []) {
	if (!isLoopbackHost(bindHost)) return true;

	return isLoopbackHost(host) || allowedHosts.includes(String(host ?? '').toLowerCase());
}

/**
 * The CORS headers for @origin. Only an origin that is not the bridge itself
 * and is listed gets any: the page of the bridge is same-origin and needs
 * none, and no origin is ever answered with `*`.
 */
/**
 * @param {string | undefined} origin
 * @param {string} host
 * @param {string[]} [allowedOrigins]
 * @returns {Record<string, string>}
 */
export function corsHeaders(origin, host, allowedOrigins = []) {
	if (!origin || !allowedOrigins.includes(origin) || originAllowed(origin, host)) return {};

	return {
		'access-control-allow-credentials': 'true',
		'access-control-allow-headers': `content-type, ${TOKEN_HEADER}`,
		'access-control-allow-methods': 'GET,POST,DELETE,OPTIONS',
		'access-control-allow-origin': origin,
		vary: 'origin'
	};
}

/** @next when it is a path of this bridge, else '/': a link must not send the browser elsewhere. */
/**
 * @param {unknown} next
 * @returns {string}
 */
export function safeNext(next) {
	const text = String(next ?? '');

	return text.startsWith('/') && !text.startsWith('//') && !text.includes('\\') ? text : '/';
}

/** The Set-Cookie value for the token. A browser keeps it for the session and a script cannot read it. */
/**
 * @param {string} token
 * @returns {string}
 */
export function tokenCookie(token) {
	return `${TOKEN_COOKIE}=${token}; HttpOnly; SameSite=Strict; Path=/`;
}
