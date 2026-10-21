// SPDX-License-Identifier: MIT
/*
 * The Electron shell of the fyai page.
 *
 * The bridge is started in this process, so the desktop app has no helper
 * program to find: it serves the built page and the API on one loopback
 * port, and the window loads that address. The page is the same bundle the
 * browser gets; there is no second user interface.
 */

'use strict';

/* A CommonJS main process: Electron loads it before a module graph exists. */
/* eslint-disable @typescript-eslint/no-require-imports */
const { app, BrowserWindow, dialog, shell } = require('electron');
const { spawn } = require('node:child_process');
const { existsSync } = require('node:fs');
const { join } = require('node:path');
const HERE = __dirname;
/*
 * In a packaged app the page lives under the application directory and the
 * extra files, such as a bundled fyai, under resources/.
 */
const ROOT = app.isPackaged ? join(process.resourcesPath, 'app') : join(HERE, '..');
const STATIC_DIR = join(ROOT, 'dist');
/* The port is fixed so that a reload of the window finds the same bridge. */
const PORT = Number(process.env.FYAI_BRIDGE_PORT ?? 9331);

let bridge = null;
let window = null;

/**
 * The fyai program: the one the environment names, else the static one
 * packaged beside the page in resources/fyai, else the one in the project
 * beside the page. A repo build is newer than a bundle made last week, so
 * the bundled one wins only when nothing else is named.
 */
function fyaiProgram() {
	const given = process.env.FYAI_BIN ?? '';
	const bundled = join(process.resourcesPath ?? '', 'fyai');
	const beside = join(ROOT, '..', 'build', 'fyai');

	if (given) return given;

	if (existsSync(bundled)) return bundled;

	if (existsSync(beside)) return beside;

	return '';
}

/** Start the bridge in a child of this process and wait for its port. */
function startBridge() {
	const args = [
		join(ROOT, 'server', 'bridge.mjs'),
		'--port',
		String(PORT),
		'--host',
		'127.0.0.1',
		'--static',
		STATIC_DIR
	];
	const model = process.env.FYAI_BRIDGE_MODEL;
	const cwd = process.env.FYAI_BRIDGE_CWD;
	const fy = fyaiProgram();

	if (fy) args.push('--bin', fy);

	if (model) args.push('--model', model);

	if (cwd) args.push('--cwd', cwd);

	console.log(`fyai: ${fy || 'fyai on PATH'}`);

	/*
	 * The bridge is a child rather than a module in this process: it starts
	 * and stops fyai processes, and a crash of it must not take the window
	 * with it.
	 */
	bridge = spawn(process.execPath, args, {
		cwd: process.env.FYAI_BRIDGE_CWD ?? ROOT,
		env: { ...process.env, ELECTRON_RUN_AS_NODE: '1' },
		stdio: ['ignore', 'pipe', 'pipe']
	});

	bridge.stdout.setEncoding('utf8');
	bridge.stdout.on('data', (chunk) => process.stdout.write(chunk));
	bridge.stderr.setEncoding('utf8');
	bridge.stderr.on('data', (chunk) => process.stderr.write(chunk));

	bridge.on('exit', (code) => {
		bridge = null;

		if (app.isReady() && !window?.isDestroyed() && code !== 0) {
			dialog.showErrorBox(
				'fyai bridge stopped',
				`The bridge exited with status ${code}. See the terminal for its report.`
			);
			app.quit();
		}
	});
}

/** Wait until the bridge answers, or give up after a few seconds. */
async function waitForBridge(ms = 20000) {
	const started = Date.now();

	while (Date.now() - started < ms) {
		try {
			const res = await fetch(`http://127.0.0.1:${PORT}/props`);

			if (res.ok) return true;
		} catch {
			/* Not listening yet. */
		}

		await new Promise((resolve) => setTimeout(resolve, 150));
	}

	return false;
}

async function createWindow() {
	if (!existsSync(join(STATIC_DIR, 'index.html'))) {
		dialog.showErrorBox(
			'No page built',
			`${STATIC_DIR} has no index.html. Run "npm run build" in the web directory.`
		);
		app.quit();

		return;
	}

	startBridge();

	if (!(await waitForBridge())) {
		dialog.showErrorBox(
			'fyai did not start',
			`The bridge did not answer on port ${PORT}. Run "npm run bridge" to see why.`
		);
		app.quit();

		return;
	}

	window = new BrowserWindow({
		backgroundColor: '#111111',
		height: 900,
		show: false,
		title: 'fyai',
		webPreferences: {
			contextIsolation: true,
			nodeIntegration: false,
			sandbox: true
		},
		width: 1200
	});

	window.once('ready-to-show', () => window.show());
	window.on('closed', () => {
		window = null;
	});

	/* A link to the outside opens in the browser, not in the app. */
	window.webContents.setWindowOpenHandler(({ url }) => {
		shell.openExternal(url);

		return { action: 'deny' };
	});

	await window.loadURL(`http://127.0.0.1:${PORT}/`);
}

app.whenReady().then(createWindow);

app.on('window-all-closed', () => {
	app.quit();
});

app.on('before-quit', () => {
	if (bridge) {
		bridge.kill('SIGTERM');
		bridge = null;
	}
});

/* A second launch shows the window of the first. */
if (!app.requestSingleInstanceLock()) app.quit();
else
	app.on('second-instance', () => {
		if (!window) return;

		if (window.isMinimized()) window.restore();

		window.focus();
	});
