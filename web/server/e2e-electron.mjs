// SPDX-License-Identifier: MIT
/*
 * Drive the desktop window over the Chrome DevTools Protocol.
 *
 *   node server/e2e-electron.mjs [PORT] [EXPECT]
 *
 * Start the app first with
 *   node_modules/.bin/electron . --remote-debugging-port=9223
 * It types a message into the window and waits for the answer.
 */

import { chromium } from 'playwright';

const debugPort = process.argv[2] ?? '9223';
const expect = process.argv[3] ?? '';
const message = process.argv[4] ?? 'hello';
const browser = await chromium.connectOverCDP(`http://127.0.0.1:${debugPort}`, {
	timeout: 60000
});
const contexts = browser.contexts();
const pages = contexts.flatMap((context) => context.pages());

if (!pages.length) {
	console.error('no window to drive');
	process.exit(2);
}

const page = pages[0];
const errors = [];

page.on('pageerror', (error) => errors.push(`pageerror: ${error.message}`));
page.on('console', (msg) => {
	if (msg.type() === 'error') errors.push(`console: ${msg.text()}`);
});

/* The window loads the bridge's page: the API answers in the same origin. */
const info = await page.evaluate(async () => {
	const res = await fetch('/api/fyai/info');

	return res.ok ? res.json() : { error: res.status };
});

await page.locator('textarea').first().waitFor({ state: 'visible', timeout: 60000 });
await page.locator('textarea').first().fill(message);
await page.locator('textarea').first().press('Enter');

let answered = false;

if (expect) {
	try {
		await page.getByText(expect, { exact: false }).first().waitFor({ timeout: 180000 });
		answered = true;
	} catch {
		answered = false;
	}
}

const text = (await page.locator('body').innerText()).slice(0, 500);

console.log(
	JSON.stringify(
		{ answered, bridge: { bin: info.bin, models: info.models?.length ?? 0 }, errors, text },
		null,
		1
	)
);

await browser.close();

process.exit(answered ? 0 : 1);
