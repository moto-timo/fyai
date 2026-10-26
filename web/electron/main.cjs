// SPDX-License-Identifier: MIT
/*
 * The Electron shell of the fyai page.
 *
 * One window is one project. Each window has a bridge of its own, started in
 * the directory of the project, which serves the built page and the API on
 * one loopback port; the window loads that address. A project is chosen on
 * the command line, in File > Open Project, or from the recent list, and a
 * project that is already open gets its window back. The page is the same
 * bundle the browser gets; there is no second user interface.
 */

'use strict';

/* A CommonJS main process: Electron loads it before a module graph exists. */
/* eslint-disable @typescript-eslint/no-require-imports */
const { app, BrowserWindow, dialog, ipcMain, Menu, shell } = require('electron');
const { spawn, spawnSync } = require('node:child_process');
const { randomBytes } = require('node:crypto');
const { existsSync, mkdirSync } = require('node:fs');
const { homedir } = require('node:os');
const { basename, dirname, join, resolve, sep } = require('node:path');
const {
	isDirectory,
	projectFromArgs,
	recentAdd,
	recentLoad,
	recentSave
} = require('./projects.cjs');
const HERE = __dirname;
/*
 * In a packaged app the page lives under the application directory and the
 * extra files, such as a bundled fyai, under resources/.
 */
const ROOT = app.isPackaged ? join(process.resourcesPath, 'app') : join(HERE, '..');
const STATIC_DIR = join(ROOT, 'dist');

/*
 * A bridge listens on a port that the system gives, because the page keeps no
 * state in the browser: the bridge holds the conversations and the settings.
 * FYAI_BRIDGE_PORT names the port of the first window only: two bridges cannot
 * share one.
 */
let firstPort = Number(process.env.FYAI_BRIDGE_PORT ?? 0);

/** The open projects by directory: {dir, bridge, window}. */
const projects = new Map();

/* Set while the app is on its way out, so a silent bridge is not an error. */
let quitting = false;

const RECENT_FILE = () => join(app.getPath('userData'), 'recent-projects.json');

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

/** True when @path is @root or inside it. */
function isInside(path, root) {
	const rel = resolve(path);
	const top = resolve(root);

	return rel === top || rel.startsWith(top + sep);
}

/** True when @dir or one of its parents holds a project arena, as fyai looks for it. */
function hasProject(dir) {
	for (let at = resolve(dir); ; at = dirname(at)) {
		if (existsSync(join(at, '.fyai', 'arena'))) return true;

		if (dirname(at) === at) return false;
	}
}

/**
 * The directory the app works in, which is the project of fyai. The one the
 * environment names wins, then the directory the app was started in. A
 * desktop launcher starts it in the bundle, in the root or in the home
 * directory, none of which is a project to put an arena in, so the app has a
 * directory of its own under the data directory of the platform.
 */
function projectDir() {
	const given = process.env.FYAI_BRIDGE_CWD;

	if (given) return resolve(given);

	const here = process.cwd();
	const stray =
		dirname(here) === here ||
		here === homedir() ||
		isInside(here, ROOT) ||
		isInside(here, process.resourcesPath ?? ROOT);

	if (!stray) return here;

	return join(app.getPath('userData'), 'project');
}

/**
 * Make @dir and give it a project when it has none: `fyai init` creates the
 * arena there. A failure is reported and the bridge still starts, so the
 * page opens and says what is missing.
 */
function ensureProject(dir, fy) {
	mkdirSync(dir, { recursive: true });

	if (hasProject(dir)) return;

	const res = spawnSync(fy || 'fyai', ['init'], {
		cwd: dir,
		encoding: 'utf8',
		env: { ...process.env },
		timeout: 30000
	});

	if (res.status !== 0)
		console.error(
			`fyai: init in ${dir} failed: ${(res.stderr || res.error?.message || '').trim()}`
		);
	else console.log(`fyai: created a project in ${dir}`);
}

/** The address the bridge reports on its first line of output. */
const LISTENING = /listening on (http:\/\/[^\s]+)/;

/**
 * Start the bridge of @project in a child of this process. Its address is
 * read from its output, because port 0 lets the system pick one.
 *
 * @param {object} project
 * @param {number} port the port to listen on, 0 for any free one
 * @returns {Promise<string>} the address the window loads
 */
function startBridge(project, port) {
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
	const fy = fyaiProgram();

	ensureProject(project.dir, fy);

	if (fy) args.push('--bin', fy);

	if (model) args.push('--model', model);

	args.push('--cwd', project.dir);

	console.log(`fyai: ${fy || 'fyai on PATH'}  project: ${project.dir}`);

	/*
	 * The bridge is a child rather than a module in this process: it starts
	 * and stops fyai processes, and a crash of it must not take the window
	 * with it.
	 */
	const bridge = spawn(process.execPath, args, {
		cwd: project.dir,
		env: { ...process.env, ELECTRON_RUN_AS_NODE: '1', FYAI_BRIDGE_TOKEN: project.token },
		/*
		 * stdin stays open for as long as this process lives: the bridge
		 * reads it to notice that it was left behind.
		 */
		stdio: ['pipe', 'pipe', 'pipe']
	});

	project.bridge = bridge;

	/* The first address the bridge prints is the one the window loads. */
	let settle;

	const listening = new Promise((resolve) => {
		let seen = false;

		settle = (address) => {
			if (seen) return;

			seen = true;
			resolve(address);
		};

		/* The bridge logs on stderr, so that is where its address appears. */
		let pending = '';

		const read = (chunk) => {
			process.stderr.write(chunk);

			pending = (pending + chunk).slice(-4096);

			const found = LISTENING.exec(pending);

			if (found) settle(found[1]);
		};

		bridge.stderr.setEncoding('utf8');
		bridge.stderr.on('data', read);
	});

	bridge.stdout.setEncoding('utf8');
	bridge.stdout.on('data', (chunk) => process.stdout.write(chunk));

	bridge.on('exit', (code) => {
		if (project.bridge === bridge) project.bridge = null;

		/* A bridge that dies before it listens leaves no address to load. */
		settle('');

		if (!quitting && project.window && !project.window.isDestroyed() && code !== 0) {
			dialog.showErrorBox(
				'fyai bridge stopped',
				`The bridge of ${project.dir} exited with status ${code}. See the terminal for its report.`
			);
			project.window.close();
		}
	});

	return listening;
}

/**
 * Stop the bridge of @project. It ends its own fyai processes, so this is the
 * one place that has to be sure it got the signal.
 */
function stopBridge(project) {
	const child = project.bridge;

	if (!child) return;

	project.bridge = null;

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

function stopAllBridges() {
	for (const project of projects.values()) stopBridge(project);
}

/** Wait until the bridge answers, or give up after a few seconds. */
async function waitForBridge(address, token, ms = 20000) {
	const started = Date.now();

	while (Date.now() - started < ms) {
		try {
			const res = await fetch(`${address}/props`, { headers: { 'x-fyai-token': token } });

			if (res.ok) return true;
		} catch {
			/* Not listening yet. */
		}

		await new Promise((resolve) => setTimeout(resolve, 150));
	}

	return false;
}

/** The title of a window: the project it works in, since every window is one. */
function windowTitle(dir) {
	return `fyai - ${basename(dir) || dir}`;
}

/** Remember @dir as the latest project, for the menu and for the operating system. */
function rememberProject(dir) {
	const list = recentAdd(recentLoad(RECENT_FILE()), dir);
	const failure = recentSave(RECENT_FILE(), list);

	if (failure) console.error(`fyai: cannot store the recent projects: ${failure}`);

	app.addRecentDocument(dir);
	buildMenu();
}

/**
 * Open the window of the project in @dir. A project that is open already is
 * brought forward, so one project never has two bridges and two windows.
 */
async function openProject(dir) {
	const key = resolve(dir);
	const open = projects.get(key);

	if (open) {
		if (open.window?.isMinimized()) open.window.restore();

		open.window?.focus();

		return;
	}

	if (!existsSync(join(STATIC_DIR, 'index.html'))) {
		dialog.showErrorBox(
			'No page built',
			`${STATIC_DIR} has no index.html. Run "npm run build" in the web directory.`
		);

		return;
	}

	/* The token of this bridge: only this app knows it, and the window logs in with it. */
	const project = { bridge: null, dir: key, token: randomBytes(32).toString('hex'), window: null };

	/* Registered at once: a second request for the project must not start another bridge. */
	projects.set(key, project);

	const fail = (title, message) => {
		dialog.showErrorBox(title, message);
		stopBridge(project);
		projects.delete(key);

		if (!projects.size) app.quit();
	};
	const wanted = firstPort;

	firstPort = 0;

	const address = await startBridge(project, wanted);

	if (!address) {
		fail(
			'fyai did not start',
			`The bridge of ${key} did not start. See the terminal for its report.`
		);

		return;
	}

	if (!(await waitForBridge(address, project.token))) {
		fail(
			'fyai did not start',
			`The bridge did not answer at ${address}. Run "npm run bridge" to see why.`
		);

		return;
	}

	const window = new BrowserWindow({
		backgroundColor: '#111111',
		height: 900,
		show: false,
		title: windowTitle(key),
		webPreferences: {
			contextIsolation: true,
			nodeIntegration: false,
			preload: join(HERE, 'preload.cjs'),
			sandbox: true
		},
		width: 1200
	});

	project.window = window;

	window.once('ready-to-show', () => window.show());
	/* The page sets its own title; the window keeps the name of its project. */
	window.on('page-title-updated', (event) => event.preventDefault());
	window.on('closed', () => {
		stopBridge(project);
		projects.delete(key);
		project.window = null;
	});

	/* The window shows this bridge only: any other address opens in the browser. */
	window.webContents.on('will-navigate', (event, url) => {
		if (url.startsWith(`${address}/`)) return;

		event.preventDefault();
		shell.openExternal(url);
	});

	/* A link to the outside opens in the browser, not in the app. */
	window.webContents.setWindowOpenHandler(({ url }) => {
		shell.openExternal(url);

		return { action: 'deny' };
	});

	rememberProject(key);

	try {
		/* The login link turns the token into a cookie of the window and goes on to the page. */
		await window.loadURL(`${address}/api/fyai/login?token=${project.token}`);
	} catch (error) {
		dialog.showErrorBox(
			'Cannot load the page',
			`${address} answered, but the page did not load: ${error.message}`
		);
		window.close();
	}
}

/** Ask for a directory and open it as a project. */
async function chooseProject() {
	const parent = BrowserWindow.getFocusedWindow() ?? undefined;
	const options = {
		buttonLabel: 'Open Project',
		properties: ['openDirectory', 'createDirectory'],
		title: 'Open a project directory'
	};
	const res = parent
		? await dialog.showOpenDialog(parent, options)
		: await dialog.showOpenDialog(options);

	if (res.canceled || !res.filePaths.length) return;

	await openProject(res.filePaths[0]);
}

/**
 * The page asks for the project actions of the menu. A channel is trusted only
 * from the window of a project: its frame is the page of that bridge.
 */
function registerIpc() {
	const known = (event) =>
		[...projects.values()].some((p) => p.window && p.window.webContents === event.sender);

	ipcMain.handle('fyai:project-choose', async (event) => {
		if (known(event)) await chooseProject();
	});
	ipcMain.handle('fyai:project-open', async (event, dir) => {
		if (!known(event) || typeof dir !== 'string' || !isDirectory(dir)) return false;

		await openProject(dir);

		return true;
	});
	ipcMain.handle('fyai:project-recent', (event) =>
		known(event) ? recentLoad(RECENT_FILE()).filter(isDirectory) : []
	);
}

/** The menu: File opens projects; the rest keeps the editing, view and window roles. */
function buildMenu() {
	const mac = process.platform === 'darwin';
	const recent = recentLoad(RECENT_FILE()).filter(isDirectory);
	const recentItems = recent.length
		? recent.map((dir) => ({ click: () => void openProject(dir), label: dir }))
		: [{ enabled: false, label: 'No recent projects' }];

	Menu.setApplicationMenu(
		Menu.buildFromTemplate([
			...(mac ? [{ role: 'appMenu' }] : []),
			{
				label: 'File',
				submenu: [
					{
						accelerator: 'CmdOrCtrl+O',
						click: () => void chooseProject(),
						label: 'Open Project...'
					},
					{ label: 'Open Recent', submenu: recentItems },
					{ type: 'separator' },
					{ role: 'close' },
					...(mac ? [] : [{ role: 'quit' }])
				]
			},
			{ role: 'editMenu' },
			{ role: 'viewMenu' },
			{ role: 'windowMenu' }
		])
	);
}

/** The project to open at start: the command line, else the environment or the start directory. */
function startProject() {
	return projectFromArgs(process.argv, process.defaultApp === true, process.cwd()) || projectDir();
}

/* A second launch opens its project, or shows a window that is open already. */
if (!app.requestSingleInstanceLock()) {
	app.quit();
} else {
	app.on('second-instance', (_event, argv, cwd) => {
		const dir = projectFromArgs(argv, false, cwd);

		if (dir) {
			void openProject(dir);

			return;
		}

		const last = [...projects.values()].pop();

		if (!last?.window) return;

		if (last.window.isMinimized()) last.window.restore();

		last.window.focus();
	});

	app
		.whenReady()
		.then(() => {
			registerIpc();
			buildMenu();

			return openProject(startProject());
		})
		.catch((error) => {
			dialog.showErrorBox('fyai did not start', error?.message ?? String(error));
			app.quit();
		});
}

app.on('window-all-closed', () => {
	app.quit();
});

/*
 * Each bridge is a child, and a child outlives its parent unless it is told
 * otherwise. Stop them on the way out, and again on the last synchronous
 * chance the process gets, which covers a quit that never reached
 * `before-quit`.
 */
app.on('before-quit', () => {
	quitting = true;
	stopAllBridges();
});

app.on('will-quit', stopAllBridges);
process.on('exit', stopAllBridges);

for (const signal of ['SIGINT', 'SIGTERM', 'SIGHUP']) {
	process.on(signal, () => {
		quitting = true;
		stopAllBridges();
		app.quit();
	});
}

process.on('uncaughtException', (error) => {
	quitting = true;
	stopAllBridges();
	console.error('fyai:', error);
	app.exit(1);
});
