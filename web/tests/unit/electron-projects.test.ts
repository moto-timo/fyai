// SPDX-License-Identifier: MIT
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';

const {
	PORT_BASE,
	PORT_COUNT,
	portForProject,
	projectFromArgs,
	RECENT_MAX,
	recentAdd,
	recentLoad,
	recentSave
} = createRequire(import.meta.url)('../../electron/projects.cjs');

let scratch: string;

beforeEach(() => {
	scratch = mkdtempSync(join(tmpdir(), 'fyai-projects-'));
});

afterEach(() => {
	rmSync(scratch, { force: true, recursive: true });
});

describe('projectFromArgs', () => {
	it('takes the first argument that is not an option', () => {
		mkdirSync(join(scratch, 'one'));

		expect(projectFromArgs(['fyai', '--flag', 'one'], false, scratch)).toBe(join(scratch, 'one'));
	});

	it('skips the application path of a development run', () => {
		mkdirSync(join(scratch, 'one'));

		expect(projectFromArgs(['electron', '.', 'one'], true, scratch)).toBe(join(scratch, 'one'));
		expect(projectFromArgs(['electron', '.'], true, scratch)).toBe('');
	});

	it('names no project for an argument that is not a directory', () => {
		writeFileSync(join(scratch, 'file'), '');

		expect(projectFromArgs(['fyai', 'file'], false, scratch)).toBe('');
		expect(projectFromArgs(['fyai', 'missing'], false, scratch)).toBe('');
	});

	it('names no project when there is no argument', () => {
		expect(projectFromArgs(['fyai'], false, scratch)).toBe('');
	});
});

describe('recent projects', () => {
	it('puts a project first and keeps it once', () => {
		expect(recentAdd(['a', 'b', 'c'], 'b')).toEqual(['b', 'a', 'c']);
	});

	it('keeps no more than the limit', () => {
		const many = Array.from({ length: RECENT_MAX }, (_, i) => `p${i}`);

		expect(recentAdd(many, 'new')).toHaveLength(RECENT_MAX);
		expect(recentAdd(many, 'new')[0]).toBe('new');
	});

	it('stores and reads the list', () => {
		const file = join(scratch, 'sub', 'recent.json');

		expect(recentSave(file, ['a', 'b'])).toBe('');
		expect(recentLoad(file)).toEqual(['a', 'b']);
	});

	it('reads a missing or damaged file as an empty list', () => {
		const file = join(scratch, 'recent.json');

		expect(recentLoad(file)).toEqual([]);

		writeFileSync(file, '{not json');

		expect(recentLoad(file)).toEqual([]);

		writeFileSync(file, JSON.stringify({ a: 1 }));

		expect(recentLoad(file)).toEqual([]);
	});

	it('drops entries that are not strings', () => {
		const file = join(scratch, 'recent.json');

		writeFileSync(file, JSON.stringify(['a', 3, null, 'b']));

		expect(recentLoad(file)).toEqual(['a', 'b']);
	});

	it('returns the cause when the list cannot be stored', () => {
		const file = join(scratch, 'plain');

		writeFileSync(file, '');

		expect(recentSave(join(file, 'recent.json'), ['a'])).not.toBe('');
	});
});

describe('portForProject', () => {
	it('gives a project the same port at every call', () => {
		expect(portForProject('/home/u/work/a')).toBe(portForProject('/home/u/work/a'));
		expect(portForProject('/home/u/work/a/')).toBe(portForProject('/home/u/work/a'));
	});

	it('keeps the port below the range of outgoing connections', () => {
		for (const dir of ['/', '/a', '/home/u/work/a', '/tmp/x y', '/very/long/'.repeat(30)]) {
			const port = portForProject(dir);

			expect(port).toBeGreaterThanOrEqual(PORT_BASE);
			expect(port).toBeLessThan(PORT_BASE + PORT_COUNT);
		}
	});

	it('spreads projects over the range', () => {
		const ports = new Set(Array.from({ length: 50 }, (_, i) => portForProject(`/work/p${i}`)));

		expect(ports.size).toBeGreaterThan(45);
	});
});
