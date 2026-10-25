// SPDX-License-Identifier: MIT
/*
 * End-to-end check of the fyai web UI: open the page, send one message and
 * read the streamed answer and the tool card. The bridge must run in front
 * of a mock provider before this script starts.
 *
 *   node server/e2e.mjs http://127.0.0.1:9331
 */

import { chromium } from 'playwright';

const base = process.argv[2] ?? 'http://127.0.0.1:9331';
/* Pairs of what to type and the text that must appear after it. */
const turns = [];

for (let i = 3; i + 1 < process.argv.length; i += 2) {
	turns.push({ expect: process.argv[i + 1], message: process.argv[i] });
}

if (!turns.length) turns.push({ expect: '', message: 'hello' });

const browser = await chromium.launch({
	args: ['--no-sandbox'],
	executablePath: process.env.CHROME_PATH ?? '/usr/bin/google-chrome'
});
const page = await browser.newPage({ viewport: { height: 900, width: 1200 } });
const errors = [];
const logs = [];

page.on('pageerror', (error) => errors.push(`pageerror: ${error.message}`));
page.on('console', (msg) => {
	if (msg.type() === 'error') errors.push(`console: ${msg.text()}`);

	if (msg.text().includes('[fyai]')) logs.push(msg.text());
});

/* The bridge answers its API only after a login with the token it started with. */
if (process.env.FYAI_BRIDGE_TOKEN) {
	await page.goto(`${base}/api/fyai/login?token=${process.env.FYAI_BRIDGE_TOKEN}`, {
		timeout: 60000,
		waitUntil: 'domcontentloaded'
	});
} else {
	await page.goto(base, { timeout: 60000, waitUntil: 'domcontentloaded' });
}

/* The composer is a textarea of the chat form. */
const input = page.locator('textarea').first();

await input.waitFor({ state: 'visible', timeout: 60000 });
let found = true;

for (const turn of turns) {
	await input.fill(turn.message);
	await input.press('Enter');

	if (!turn.expect) continue;

	try {
		await page.getByText(turn.expect, { exact: false }).first().waitFor({ timeout: 60000 });
	} catch {
		found = false;
	}
}

const expect = turns[turns.length - 1].expect;

await page.waitForTimeout(1500);
await page.screenshot({ fullPage: true, path: '/tmp/fyai-web-e2e.png' });

const text = await page.locator('body').innerText();
/* Where each copy of the answer stands, to tell a duplicate row from a redraw. */
const copies = await page.evaluate((needle) => {
	const hits = [];

	for (const el of document.querySelectorAll('*')) {
		if (el.children.length) continue;

		const own = (el.textContent ?? '').trim();

		if (own.includes(needle)) {
			hits.push({
				class: el.className?.toString().slice(0, 80),
				parent: el.parentElement?.className?.toString().slice(0, 80),
				tag: el.tagName,
				text: own.slice(0, 80)
			});
		}
	}

	return hits;
}, expect);

console.log(
	JSON.stringify({ copies, errors, expect, found, logs, text: text.slice(0, 1200) }, null, 2)
);

await browser.close();

if (!found) process.exit(1);
