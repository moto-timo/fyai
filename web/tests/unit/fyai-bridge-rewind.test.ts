// SPDX-License-Identifier: MIT
import { type ChildProcess, spawn } from 'node:child_process';
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';

const BRIDGE = join(__dirname, '../../server/bridge.mjs');
const FAKE = join(__dirname, '../fixtures/fake-fyai.mjs');
const TOKEN = 'rewind-token';

let scratch: string;
let child: ChildProcess;
let base: string;

beforeAll(async () => {
	scratch = mkdtempSync(join(tmpdir(), 'fyai-bridge-rewind-'));
	chmodSync(FAKE, 0o755);
	writeFileSync(join(scratch, 'state.json'), JSON.stringify({ branches: { main: { turns: 0 } } }));
	child = spawn(
		process.execPath,
		[BRIDGE, '--bin', FAKE, '--cwd', scratch, '--port', '0', '--token', TOKEN],
		{
			env: { ...process.env, FAKE_FYAI_STATE: join(scratch, 'state.json') },
			stdio: ['pipe', 'pipe', 'pipe']
		}
	);

	base = await new Promise<string>((resolve, reject) => {
		let seen = '';

		child.stderr!.setEncoding('utf8');
		child.stderr!.on('data', (chunk: string) => {
			seen += chunk;

			const found = /listening on (http:\/\/\S+)/.exec(seen);

			if (found) resolve(found[1]);
		});
		child.on('exit', (code) => reject(new Error(`the bridge exited with ${code}: ${seen}`)));
	});
});

afterAll(() => {
	child.kill('SIGTERM');
	rmSync(scratch, { force: true, recursive: true });
});

const headers = { 'content-type': 'application/json', 'x-fyai-token': TOKEN };

type Anchor = { occurrence: number; text: string } | null | undefined;

/** Run one turn and return the text of its frames. */
async function turn(conversationId: string, prompt: string, anchor: Anchor) {
	const body: Record<string, unknown> = { conversationId, prompt };

	if (anchor !== undefined) body.anchor = anchor;

	const res = await fetch(`${base}/api/fyai/chat`, {
		body: JSON.stringify(body),
		headers,
		method: 'POST'
	});

	return res.text();
}

async function history(conversationId: string): Promise<string[]> {
	const res = await fetch(`${base}/api/fyai/conversations/${conversationId}/messages`, { headers });
	const body = await res.json();

	return body.messages.map((m: { content: string }) => m.content);
}

describe('a turn that follows an earlier message', () => {
	it('adds to the branch when the turn follows the last message', async () => {
		await turn('a', 'one', null);
		await turn('a', 'two', { occurrence: 1, text: 'one' });

		expect(await history('a')).toEqual(['one', 'answer to one', 'two', 'answer to two']);
	});

	it('cuts the last exchange when the turn follows an earlier message (regenerate)', async () => {
		await turn('b', 'one', null);
		await turn('b', 'two', { occurrence: 1, text: 'one' });
		await turn('b', 'two', { occurrence: 1, text: 'one' });

		expect(await history('b')).toEqual(['one', 'answer to one', 'two', 'answer to two']);
	});

	it('cuts back to the anchor when the page edited an earlier message', async () => {
		await turn('c', 'one', null);
		await turn('c', 'two', { occurrence: 1, text: 'one' });
		await turn('c', 'three', { occurrence: 1, text: 'two' });
		/* Edit of 'two': the turn follows 'one'. */
		await turn('c', 'two edited', { occurrence: 1, text: 'one' });

		expect(await history('c')).toEqual([
			'one',
			'answer to one',
			'two edited',
			'answer to two edited'
		]);
	});

	it('starts the branch again when the first message is edited or regenerated', async () => {
		await turn('d', 'one', null);
		await turn('d', 'two', { occurrence: 1, text: 'one' });
		await turn('d', 'one edited', null);

		expect(await history('d')).toEqual(['one edited', 'answer to one edited']);
	});

	it('finds the right one of two equal messages by its count', async () => {
		await turn('e', 'same', null);
		await turn('e', 'same', { occurrence: 1, text: 'same' });
		await turn('e', 'next', { occurrence: 2, text: 'same' });
		await turn('e', 'again', { occurrence: 1, text: 'same' });

		expect(await history('e')).toEqual(['same', 'answer to same', 'again', 'answer to again']);
	});

	it('goes on when the anchor is not in the branch', async () => {
		await turn('f', 'one', null);

		const text = await turn('f', 'two', { occurrence: 1, text: 'missing' });

		expect(text).not.toContain('cannot be matched');
		expect(await history('f')).toEqual(['one', 'answer to one', 'two', 'answer to two']);
	});

	it('stops the turn when the branch cannot be cut back', async () => {
		await turn('h', 'one', null);
		await turn('h', 'two', { occurrence: 1, text: 'one' });

		const file = join(scratch, 'state.json');
		const state = JSON.parse(readFileSync(file, 'utf8'));

		state.branches['h'].stuck = true;
		writeFileSync(file, JSON.stringify(state));

		const text = await turn('h', 'two again', { occurrence: 1, text: 'one' });

		expect(text).toContain('cannot be matched to the page');
		expect(await history('h')).toEqual(['one', 'answer to one', 'two', 'answer to two']);
	});

	it('leaves no copy of the branch behind', async () => {
		const res = await fetch(`${base}/api/fyai/conversations`, { headers });
		const ids: string[] = (await res.json()).conversations.map((c: { id: string }) => c.id);

		expect(ids.filter((id) => id.includes('rewind'))).toEqual([]);
	});

	it('does not check a request that names no anchor', async () => {
		await turn('g', 'one', undefined);
		await turn('g', 'two', undefined);

		expect(await history('g')).toEqual(['one', 'answer to one', 'two', 'answer to two']);
	});
});

describe('images of a turn', () => {
	const png = Buffer.from([0x89, 0x50, 0x4e, 0x47, 1, 2, 3]);

	async function send(body: Record<string, unknown>) {
		const res = await fetch(`${base}/api/fyai/chat`, {
			body: JSON.stringify({ conversationId: 'img', ...body }),
			headers,
			method: 'POST'
		});

		return { status: res.status, text: await res.text() };
	}

	async function first(conversationId: string) {
		const res = await fetch(`${base}/api/fyai/conversations/${conversationId}/messages`, {
			headers
		});

		return (await res.json()).messages[0];
	}

	it('sends each image as a block of the user message', async () => {
		const out = await send({
			images: [
				{ data: png.toString('base64'), mediaType: 'image/png', name: 'a.png' },
				{ data: png.toString('base64'), mediaType: 'image/webp', name: 'b.webp' }
			],
			prompt: 'what is this'
		});

		expect(out.status).toBe(200);

		const message = await first('img');

		expect(message.content).toBe('what is this');
		expect(message.images).toEqual([
			{ mediaType: 'image/png', size: png.length },
			{ mediaType: 'image/webp', size: png.length }
		]);
	});

	it('takes a message of images alone', async () => {
		const out = await send({
			conversationId: 'img2',
			images: [{ data: png.toString('base64'), mediaType: 'image/jpeg', name: 'a.jpg' }],
			prompt: ''
		});

		expect(out.status).toBe(200);

		const message = await first('img2');

		expect(message.content).toBe('');
		expect(message.images).toHaveLength(1);
	});

	it('sends no block for a turn with no image', async () => {
		await send({ conversationId: 'img3', prompt: 'plain' });

		expect((await first('img3')).images).toEqual([]);
	});

	it('refuses a type that fyai does not take, bad data, and no prompt at all', async () => {
		const data = png.toString('base64');

		expect((await send({ images: [{ data, mediaType: 'image/bmp' }], prompt: 'x' })).status).toBe(
			400
		);
		expect(
			(await send({ images: [{ data: 'not base64!', mediaType: 'image/png' }], prompt: 'x' }))
				.status
		).toBe(400);
		expect(
			(await send({ images: [{ data: '', mediaType: 'image/png' }], prompt: 'x' })).status
		).toBe(400);
		expect((await send({ images: 'x', prompt: 'x' })).status).toBe(400);
		expect((await send({ prompt: '  ' })).status).toBe(400);
	});
});
