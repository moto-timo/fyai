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

/*
 * Port 0 asks the system for a free one, which the bridge reports and this
 * process then uses. A fixed port would collide with a second window of the
 * app, with a development bridge, or with a stale one of either; a reload of
 * the window finds the same bridge because the address never changes while
 * the app runs.
 */
let port = Number(process.env.FYAI_BRIDGE_PORT ?? 0);
let bridge = null;
let window = null;
/* Set while the app is on its way out, so a silent bridge is not an error. */
let quitting = false;

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

/** The address the bridge reports on its first line of output. */
const LISTENING = /listening on (http:\/\/[^\s]+)/;

/**
 * Start the bridge in a child of this process. Its address is read from its
 * output, because port 0 lets the system pick one.
 *
 * @returns {Promise<string>} the address the window loads
 */
function startBridge() {
	const args = [
		join(ROOT, 'server', 'bridge.mjs'),
		'--port',
		String(port),
		'--host',
		'127.0.0.1',
		'--static',
		STATIC_DIR,
		/*
		 * So the bridge stops with this process, even when the window is
		 * killed rather than quit: a bridge left behind would hold the port
		 * and keep any running turn alive.
		 */
		'--parent-pid',
		String(process.pid)
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
		/*
		 * stdin stays open for as long as this process lives: the bridge
		 * reads it to notice that it was left behind.
		 */
		stdio: ['pipe', 'pipe', 'pipe']
	});

	/* The first address the bridge prints is the one the window loads. */
	let settle;

	const listening = new Promise((resolve) => {
		let seen = false;

		settle = (address) => {
			if (seen) return;

			seen = true;
			resolve(address);
		};

		const read = (chunk) => {
			process.stdout.write(chunk);

			const found = LISTENING.exec(chunk);

			if (found) settle(found[1]);
		};

		bridge.stdout.setEncoding('utf8');
		bridge.stdout.on('data', read);
	});

	bridge.stderr.setEncoding('utf8');
	bridge.stderr.on('data', (chunk) => process.stderr.write(chunk));

	bridge.on('exit', (code) => {
		bridge = null;
		/* A bridge that dies before it listens leaves no address to load. */
		settle('');

		if (!quitting && app.isReady() && !window?.isDestroyed() && code !== 0) {
			dialog.showErrorBox(
				'fyai bridge stopped',
				`The bridge exited with status ${code}. See the terminal for its report.`
			);
			app.quit();
		}
	});

	return listening;
}

/**
 * Stop the bridge and wait a moment for it. It ends its own fyai processes,
 * so this is the one place that has to be sure it got the signal.
 */
function stopBridge() {
	if (!bridge) return;

	const child = bridge;

	bridge = null;

	try {
		child.kill('SIGTERM');
	} catch {
		return;
	}

	/* An app that is already gone cannot wait for a polite exit. */
	setTimeout(() => {
		try {
			child.kill('SIGKILL');
		} catch {
			/* It ended on its own. */
		}
	}, 3000).unref();
}

/** Wait until the bridge answers, or give up after a few seconds. */
async function waitForBridge(address, ms = 20000) {
	const started = Date.now();

	while (Date.now() - started < ms) {
		try {
			const res = await fetch(`${address}/props`);

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

	const address = await startBridge();

	if (!address) {
		app.quit();

		return;
	}

	if (!(await waitForBridge(address))) {
		dialog.showErrorBox(
			'fyai did not start',
			`The bridge did not answer at ${address}. Run "npm run bridge" to see why.`
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

	try {
		await window.loadURL(`${address}/`);
	} catch (error) {
		dialog.showErrorBox(
			'Cannot load the page',
			`${address} answered, but the page did not load: ${error.message}`
		);
		app.quit();
	}
}

app
	.whenReady()
	.then(createWindow)
	.catch((error) => {
		dialog.showErrorBox('fyai did not start', error?.message ?? String(error));
		app.quit();
	});

app.on('window-all-closed', () => {
	app.quit();
});

/*
 * The bridge is a child, and a child outlives its parent unless it is told
 * otherwise. Stop it on the way out, and again on the last synchronous chance
 * the process gets, which covers a quit that never reached `before-quit`.
 */
app.on('before-quit', () => {
	quitting = true;
	stopBridge();
});

app.on('will-quit', stopBridge);
process.on('exit', stopBridge);

for (const signal of ['SIGINT', 'SIGTERM', 'SIGHUP']) {
	process.on(signal, () => {
		quitting = true;
		stopBridge();
		app.quit();
	});
}

process.on('uncaughtException', (error) => {
	quitting = true;
	stopBridge();
	console.error('fyai:', error);
	app.exit(1);
});

/* A second launch shows the window of the first. */
if (!app.requestSingleInstanceLock()) app.quit();
else
	app.on('second-instance', () => {
		if (!window) return;

		if (window.isMinimized()) window.restore();

		window.focus();
	});
