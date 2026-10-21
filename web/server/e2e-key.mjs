// SPDX-License-Identifier: MIT
/*
 * End-to-end check of the key settings: put a provider key in the page's
 * settings the way a person does, then send one message and read the answer.
 *
 *   KEY=sk-... node server/e2e-key.mjs http://127.0.0.1:9363 1
 *
 * The last argument is 1 for the "Provider API keys" field
 * (`anthropic = KEY`) and 0 for the single "API Key" field.
 */

import { chromium } from 'playwright';

const base = process.argv[2] ?? 'http://127.0.0.1:9331';
const useProviderMap = (process.argv[3] ?? '1') === '1';
const key = process.env.KEY ?? '';

if (!key) {
	console.error('e2e-key.mjs: set KEY to the provider key');
	process.exit(2);
}

const browser = await chromium.launch({
	args: ['--no-sandbox'],
	executablePath: process.env.CHROME_PATH ?? '/usr/bin/google-chrome'
});
const page = await browser.newPage({ viewport: { height: 900, width: 1200 } });
const errors = [];

page.on('pageerror', (error) => errors.push(`pageerror: ${error.message}`));
page.on('console', (msg) => {
	if (msg.type() === 'error') errors.push(`console: ${msg.text()}`);
});

/* Write the setting before the page reads it, as the settings form would. */
await page.addInitScript(
	({ map, secret }) => {
		const name = 'LlamaUi.config';

		let config = {};

		try {
			config = JSON.parse(localStorage.getItem(name) ?? '{}') ?? {};
		} catch {
			config = {};
		}

		if (map) config.providerApiKeys = `anthropic = ${secret}`;
		else config.apiKey = secret;

		localStorage.setItem(name, JSON.stringify(config));
	},
	{ map: useProviderMap, secret: key }
);

await page.goto(base, { waitUntil: 'domcontentloaded' });

const input = page.locator('textarea').first();

await input.waitFor({ state: 'visible', timeout: 60000 });
await input.fill('say hello');
await input.press('Enter');

/*
 * The send button turns into Stop while the turn runs, so the turn is over
 * when Stop leaves the screen.
 */
let answered = false;

try {
	await page.getByText('Stop', { exact: true }).first().waitFor({ timeout: 60000 });
	await page
		.getByText('Stop', { exact: true })
		.first()
		.waitFor({ state: 'hidden', timeout: 180000 });
	answered = true;
} catch {
	answered = false;
}

const text = await page.locator('body').innerText();
const failed = text.includes('Server Error') || text.includes('no API key');

console.log(
	JSON.stringify(
		{
			answered,
			errors,
			failed,
			mode: useProviderMap ? 'provider map' : 'single key',
			text: text.slice(0, 400)
		},
		null,
		1
	)
);

await browser.close();

process.exit(answered && !failed ? 0 : 1);
