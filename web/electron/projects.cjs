// SPDX-License-Identifier: MIT
/*
 * The project choices of the desktop app that need no Electron: which
 * directory a command line names, and the list of recent projects. The main
 * process supplies the paths, so a test can run them in a scratch directory.
 */

'use strict';

/* A CommonJS module: the Electron main process loads it with require(). */
/* eslint-disable @typescript-eslint/no-require-imports */

const { mkdirSync, readFileSync, statSync, writeFileSync } = require('node:fs');
const { dirname, resolve } = require('node:path');
const RECENT_MAX = 10;

/** True when @path is a directory. */
function isDirectory(path) {
	try {
		return statSync(path).isDirectory();
	} catch {
		return false;
	}
}

/**
 * The project that a command line names: the first argument that is not an
 * option, when it is a directory. A development run is `electron . DIR`, so
 * its arguments start after the application path; a packaged one has no such
 * entry.
 *
 * @param {string[]} argv the arguments of the process
 * @param {boolean} defaultApp true when run as `electron PATH`
 * @param {string} cwd the directory a relative argument is taken from
 * @returns {string} the absolute directory, or '' when there is none
 */
function projectFromArgs(argv, defaultApp, cwd) {
	for (const arg of argv.slice(defaultApp ? 2 : 1)) {
		if (arg.startsWith('-')) continue;

		const dir = resolve(cwd, arg);

		return isDirectory(dir) ? dir : '';
	}

	return '';
}

/** The list with @dir first, once, and no more than @max entries. */
function recentAdd(list, dir, max = RECENT_MAX) {
	return [dir, ...list.filter((entry) => entry !== dir)].slice(0, max);
}

/** The recent projects stored in @file; a missing or damaged file is an empty list. */
function recentLoad(file) {
	try {
		const data = JSON.parse(readFileSync(file, 'utf8'));

		return Array.isArray(data) ? data.filter((entry) => typeof entry === 'string') : [];
	} catch {
		return [];
	}
}

/** Store the list. A failure is returned, not thrown: losing the list must not stop the app. */
function recentSave(file, list) {
	try {
		mkdirSync(dirname(file), { recursive: true });
		writeFileSync(file, `${JSON.stringify(list)}\n`);

		return '';
	} catch (error) {
		return error?.message ?? String(error);
	}
}

module.exports = {
	isDirectory,
	projectFromArgs,
	RECENT_MAX,
	recentAdd,
	recentLoad,
	recentSave
};
