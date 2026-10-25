#!/usr/bin/env node
// SPDX-License-Identifier: MIT
/*
 * End-to-end check of the page in a browser, against the bridge, the real fyai
 * and the mock provider of fyai. Nothing leaves the machine and no key is
 * needed: the provider is `fyai __mock-server` with the scenario
 * tests/scenarios/web_chat.json, and every directory is private.
 *
 *   node server/e2e-mock.mjs [--fyai BIN] [--chrome PATH] [--scenario FILE] [--keep]
 *
 * It needs the built page (web/dist, or FYAI_BRIDGE_STATIC), a Chrome or the
 * Chromium of Playwright, and a fyai binary (--fyai, $FYAI_BIN, ../build/fyai).
 * The mock answers in order, so each step of the script knows which answer it
 * waits for: "Mock answer N" is the N-th request of the run.
 */

import { spawn, spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(HERE, '..');
const args = process.argv.slice(2);
const option = (name, fallback = '') => {
	const at = args.indexOf(`--${name}`);

	return at >= 0 && args[at + 1] ? args[at + 1] : fallback;
};
const SCALE = Number(process.env.FYAI_TIMEOUT_SCALE ?? 1);
const FYAI = resolve(option('fyai', process.env.FYAI_BIN ?? join(ROOT, '..', 'build', 'fyai')));
const CHROME = option('chrome', process.env.CHROME ?? '');
const STATIC = resolve(process.env.FYAI_BRIDGE_STATIC ?? join(ROOT, 'dist'));
const SCENARIO = resolve(
	option('scenario', join(ROOT, '..', 'tests', 'scenarios', 'web_chat.json'))
);
const TOKEN = 'e2e-mock-token';
/* A PNG header is all fyai needs: it sniffs the type and reads the size from it. */
const PNG = Buffer.from(
	'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg==',
	'base64'
);
const base = mkdtempSync(join(tmpdir(), 'fyai-web-e2e-'));
const home = join(base, 'home');
const work = join(base, 'work');
const env = {
	FYAI_AUTH_STORAGE: 'file',
	HOME: home,
	MOCK_KEY: 'test-key',
	PATH: process.env.PATH,
	TMPDIR: join(base, 'tmp'),
	XDG_CONFIG_HOME: join(home, '.config'),
	XDG_STATE_HOME: join(home, '.local', 'state')
};
const children = [];

for (const dir of [home, work, env.TMPDIR]) mkdirSync(dir, { recursive: true });

function fail(message) {
	console.error(`e2e-mock: ${message}`);
	cleanup();
	process.exit(2);
}

function cleanup() {
	for (const child of children) child.kill('SIGTERM');

	if (!args.includes('--keep')) rmSync(base, { force: true, recursive: true });
	else console.error(`e2e-mock: kept ${base}`);
}

process.on('exit', cleanup);

function run(program, programArgs) {
	const res = spawnSync(program, programArgs, { cwd: work, encoding: 'utf8', env });

	if (res.status !== 0) fail(`${program} ${programArgs.join(' ')}: ${res.stderr || res.stdout}`);
}

/** Resolve with the first match of @pattern in the stderr of @child. */
function firstLine(child, pattern) {
	return new Promise((done, failed) => {
		let seen = '';

		child.stderr.setEncoding('utf8');
		child.stderr.on('data', (chunk) => {
			seen += chunk;

			const found = pattern.exec(seen);

			if (found) done(found);
		});
		child.on('exit', (code) => failed(new Error(`exited with ${code}: ${seen}`)));
	});
}

if (!existsSync(FYAI)) fail(`no fyai at ${FYAI}: give --fyai or set FYAI_BIN`);

if (!existsSync(join(STATIC, 'index.html'))) fail(`no built page at ${STATIC}: build it first`);

/* The mock provider. */
const mock = spawn(FYAI, ['__mock-server', SCENARIO, base], {
	env,
	stdio: ['ignore', 'ignore', 'pipe']
});

children.push(mock);

for (let i = 0; !existsSync(join(base, 'port')); i++) {
	if (i > 200 * SCALE) fail('the mock provider did not bind');

	await new Promise((r) => setTimeout(r, 50));
}

const mockUrl = `http://127.0.0.1:${readFileSync(join(base, 'port'), 'utf8').trim()}`;

/* A model that takes images, so one case can attach one. */
writeFileSync(
	join(work, 'catalog.yaml'),
	`models:
- name: img-chat
  modalities: [text, image]
  capabilities: [tool_calling]
providers:
- name: chat-prov
  root_url: ${mockUrl}
  endpoints:
  - protocol: chat_completions
    endpoint: /v1/chat/completions
  models:
  - canonical_id: img-chat
    provider_model_id: img-chat
`
);
run(FYAI, ['init']);
run(FYAI, ['catalog', 'import', 'catalog.yaml']);
run(FYAI, [
	'--set',
	'api=chat-completions',
	'--set',
	`api_url=${mockUrl}/v1/chat/completions`,
	'--set',
	'model=chat-prov/img-chat',
	'--set',
	'api_key={type: env, value: MOCK_KEY}'
]);

/* The bridge. */
const bridge = spawn(
	process.execPath,
	[
		join(HERE, 'bridge.mjs'),
		'--bin',
		FYAI,
		'--cwd',
		work,
		'--port',
		'0',
		'--static',
		STATIC,
		'--token',
		TOKEN
	],
	{ env, stdio: ['pipe', 'pipe', 'pipe'] }
);

children.push(bridge);

const address = (await firstLine(bridge, /listening on (http:\/\/\S+)/))[1];
/* ------------------------------------------------------------ the browser */
const browser = await chromium.launch(CHROME ? { executablePath: CHROME } : {});
const page = await (await browser.newContext({ viewport: { height: 900, width: 1280 } })).newPage();
const problems = [];

page.on('pageerror', (error) => problems.push(`pageerror: ${error.message}`));
page.setDefaultTimeout(30000 * SCALE);

const bridgeJson = (path, init) =>
	page.evaluate(async ([p, i]) => (await fetch(p, i)).json(), [path, init]);
/** The user and assistant messages of the newest conversation, as `role:text`. */
const branchLines = async () => {
	const { conversations } = await bridgeJson('/api/fyai/conversations');

	if (!conversations.length) return [];

	const { messages } = await bridgeJson(
		`/api/fyai/conversations/${encodeURIComponent(conversations[0].id)}/messages`
	);

	return messages
		.filter((m) => m.role === 'user' || m.role === 'assistant')
		.map((m) => `${m.role[0]}:${typeof m.content === 'string' ? m.content : '[parts]'}`);
};
/** The bodies of the requests that the mock got, in order. */
const requests = () =>
	existsSync(join(base, 'requests.jsonl'))
		? readFileSync(join(base, 'requests.jsonl'), 'utf8')
				.split('\n')
				.filter(Boolean)
				.map((line) => JSON.parse(line))
		: [];
const visible = (text) => page.getByText(text, { exact: false }).first().waitFor();
const composer = () => page.locator('textarea').first();
const send = async (text) => {
	await composer().fill(text);
	await composer().press('Enter');
};
/** Wait until the branch holds exactly @lines. */
const branchIs = async (lines) => {
	let last = [];

	for (let i = 0; i < 120 * SCALE; i++) {
		last = await branchLines();

		if (JSON.stringify(last) === JSON.stringify(lines)) return;

		await page.waitForTimeout(250);
	}

	throw new Error(`the branch is ${JSON.stringify(last)}, not ${JSON.stringify(lines)}`);
};
const assert = (condition, message) => {
	if (!condition) throw new Error(message);
};

await page.goto(`${address}/api/fyai/login?token=${TOKEN}`, { waitUntil: 'domcontentloaded' });
await composer().waitFor();

const cases = [];
const test = (name, body) => cases.push([name, body]);

test('the page knows the bridge and hides what fyai does not use', async () => {
	const info = await bridgeJson('/api/fyai/info');

	assert(info.authenticated === true && info.backend === 'fyai', JSON.stringify(info));

	const buttons = await page.evaluate(() =>
		[...document.querySelectorAll('button')].map((b) => b.getAttribute('aria-label') ?? '')
	);

	assert(!buttons.includes('Models') && !buttons.includes('MCP'), `buttons: ${buttons}`);
});

test('a turn is answered and stored as a branch of fyai', async () => {
	await send('First question');
	await visible('Mock answer 1');
	await branchIs(['u:First question', 'a:Mock answer 1']);
});

test('the next turn follows the first', async () => {
	await send('Second question');
	await visible('Mock answer 2');
	await branchIs(['u:First question', 'a:Mock answer 1', 'u:Second question', 'a:Mock answer 2']);
});

test('regenerate cuts the last exchange and asks again', async () => {
	await page.getByRole('button', { name: 'Regenerate' }).last().click();
	await visible('Mock answer 3');
	await branchIs(['u:First question', 'a:Mock answer 1', 'u:Second question', 'a:Mock answer 3']);

	const third = requests()[2]?.body?.messages ?? [];
	const roles = third.map((m) => m.role).filter((r) => r !== 'system');

	assert(
		JSON.stringify(roles) === JSON.stringify(['user', 'assistant', 'user']),
		`the request after the cut held ${roles}`
	);
});

test('an edit of the first message starts the conversation again', async () => {
	await page.getByRole('button', { name: 'Edit' }).first().click();
	await composer().fill('Edited first question');
	await page.getByRole('button', { name: 'Send' }).first().click();
	await visible('Mock answer 4');
	await branchIs(['u:Edited first question', 'a:Mock answer 4']);

	const fourth = requests()[3]?.body?.messages ?? [];

	assert(
		fourth.filter((m) => m.role === 'user').length === 1,
		'the request of the edit still held the old messages'
	);
});

test('a task list call shows as a list', async () => {
	await send('Make a plan');
	await visible('Mock answer 6');
	await visible('Task list');
	await visible('Write the fix');
	await visible('1 of 2 done');
});

test('a shell call shows its command and its output', async () => {
	await send('Run something');
	await visible('Mock answer 8');
	await visible('echo from the mock');
});

test('an image goes to fyai as an attachment of the message', async () => {
	await page.setInputFiles('input[type="file"]', {
		buffer: PNG,
		mimeType: 'image/png',
		name: 'shot.png'
	});
	await send('Look at this');
	await visible('Mock answer 9');

	const body = requests()[8]?.body?.messages ?? [];
	const user = body.filter((m) => m.role === 'user').at(-1);
	const parts = Array.isArray(user?.content) ? user.content : [];

	assert(
		parts.some(
			(p) => p.type === 'image_url' && p.image_url.url.startsWith('data:image/png;base64,')
		),
		`the request carried ${JSON.stringify(user)?.slice(0, 200)}`
	);
});

test('a conversation comes back from fyai when the page has lost its copy', async () => {
	/* The page holds no copy: a new load reads the conversation from fyai. */
	await page.evaluate(() => localStorage.clear());
	await page.goto(`${address}/`, { waitUntil: 'domcontentloaded' });
	await composer().waitFor();
	/* The list of the sidebar: the page made its copy again from fyai. */
	await page.locator('button[aria-label="Expand navigation"]').click();
	await page.getByText('Edited first question').first().click();
	await visible('Mock answer 4');
	await visible('Task list');
	await visible('echo from the mock');

	/* The browser keeps no database, and the branch is named as the CLI names one. */
	assert(
		(await page.evaluate(async () => (await indexedDB.databases()).length)) === 0,
		'the browser holds a database'
	);
	assert(
		/^session\/\d{8}T\d{6}\.\d{6}$/.test(
			(await bridgeJson('/api/fyai/conversations')).conversations[0].id
		),
		'the branch does not have a name of the CLI'
	);

	/* The image of the last message came back with its bytes. */
	assert(
		(await page.locator('img[src^="data:image/png;base64,"]').count()) > 0,
		'the restored message has no image'
	);
});

let failed = 0;

for (const [name, body] of cases) {
	try {
		await body();
		console.log(`ok - ${name}`);
	} catch (error) {
		failed++;
		console.log(`not ok - ${name}\n  ${error.message}`);
		await page.screenshot({ path: join(base, `failed-${failed}.png`) }).catch(() => {});
	}
}

if (problems.length) console.log(`page errors: ${JSON.stringify(problems)}`);

await browser.close();
console.log(
	failed ? `${failed} of ${cases.length} failed (${base})` : `all ${cases.length} passed`
);
process.exit(failed ? 1 : 0);
