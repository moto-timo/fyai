// SPDX-License-Identifier: MIT
import { AttachmentType, MessageRole } from '$lib/enums';
import {
	buildFyaiPrompt,
	fyaiAnchor,
	fyaiImages,
	fyaiUnsupportedAttachments,
	messageText,
	parseProviderKeys
} from '$lib/services/fyai.service';
import type { DatabaseMessage } from '$lib/types';
import { describe, expect, it } from 'vitest';

function message(role: string, content: unknown, extra?: unknown[]): DatabaseMessage {
	return {
		children: [],
		content,
		convId: 'c1',
		id: Math.random().toString(36).slice(2),
		parent: null,
		role,
		timestamp: 0,
		type: 'text',
		...(extra ? { extra } : {})
	} as unknown as DatabaseMessage;
}

describe('messageText', () => {
	it('returns a string content as it stands', () => {
		expect(messageText('hello')).toBe('hello');
	});

	it('joins the text parts of a content list', () => {
		expect(
			messageText([
				{ text: 'a', type: 'text' },
				{ text: 'b', type: 'text' }
			] as never)
		).toBe('ab');
	});
});

describe('buildFyaiPrompt', () => {
	it('takes the text of the last user message', () => {
		expect(
			buildFyaiPrompt([
				message(MessageRole.USER, 'first'),
				message(MessageRole.ASSISTANT, 'answer'),
				message(MessageRole.USER, 'second')
			])
		).toBe('second');
	});

	it('adds the content of a text file', () => {
		const prompt = buildFyaiPrompt([
			message(MessageRole.USER, 'look at this', [
				{ content: 'x = 1', name: 'a.py', type: AttachmentType.TEXT }
			])
		]);

		expect(prompt).toContain('look at this');
		expect(prompt).toContain('File a.py:');
		expect(prompt).toContain('x = 1');
	});

	it('leaves an image out', () => {
		const prompt = buildFyaiPrompt([
			message(MessageRole.USER, 'what is this', [
				{ base64Url: 'data:image/png;base64,AAAA', name: 'a.png', type: AttachmentType.IMAGE }
			])
		]);

		expect(prompt).toBe('what is this');
	});

	it('gives nothing for a user message with no text', () => {
		expect(
			buildFyaiPrompt([message(MessageRole.USER, '   '), message(MessageRole.ASSISTANT, 'x')])
		).toBeNull();
	});

	it('gives nothing without a user message', () => {
		expect(buildFyaiPrompt([message(MessageRole.ASSISTANT, 'x')])).toBeNull();
	});
});

describe('parseProviderKeys', () => {
	it('reads one provider a line', () => {
		expect(parseProviderKeys('anthropic = sk-ant-1\nopenai = sk-oai-2')).toEqual({
			anthropic: 'sk-ant-1',
			openai: 'sk-oai-2'
		});
	});

	it('takes the provider name in lower case and trims the parts', () => {
		expect(parseProviderKeys('  OpenAI   =   sk-1  ')).toEqual({ openai: 'sk-1' });
	});

	it('leaves a blank row, a comment and a row with no value out', () => {
		expect(parseProviderKeys('\n# openai = sk-1\nanthropic =\n= broken\n')).toEqual({});
	});

	it('keeps a key that holds an equals sign', () => {
		expect(parseProviderKeys('deepseek = a=b=c')).toEqual({ deepseek: 'a=b=c' });
	});

	it('gives nothing for an empty field', () => {
		expect(parseProviderKeys('')).toEqual({});
	});
});

describe('fyaiAnchor', () => {
	const user = (content: string, extra: Partial<DatabaseMessage> = {}) =>
		({ content, role: 'user', ...extra }) as DatabaseMessage;
	const assistant = (content: string) => ({ content, role: 'assistant' }) as DatabaseMessage;

	it('is null for the first message of a conversation', () => {
		expect(fyaiAnchor([user('one')])).toBeNull();
		expect(fyaiAnchor([])).toBeNull();
	});

	it('names the last user message before the one that starts the turn', () => {
		const path = [user('one'), assistant('a'), user('two'), assistant('b'), user('three')];

		expect(fyaiAnchor(path)).toEqual({ occurrence: 1, text: 'two' });
	});

	it('counts equal messages up to the anchor', () => {
		const path = [user('same'), assistant('a'), user('same'), assistant('b'), user('next')];

		expect(fyaiAnchor(path)).toEqual({ occurrence: 2, text: 'same' });
	});

	it('does not count a message that the page made itself', () => {
		const path = [
			user('one'),
			assistant('a'),
			user('cwd changed', { isSynthetic: true }),
			user('two')
		];

		expect(fyaiAnchor(path)).toEqual({ occurrence: 1, text: 'one' });
	});

	it('uses the prompt that was sent, with the text of its files', () => {
		const first = user('look', {
			extra: [{ content: 'body', name: 'a.txt', type: AttachmentType.TEXT }] as never
		});

		expect(fyaiAnchor([first, assistant('a'), user('two')])?.text).toBe(buildFyaiPrompt([first]));
	});
});

describe('fyaiImages and fyaiUnsupportedAttachments', () => {
	const withExtra = (extra: unknown[]) =>
		[
			{ content: 'look', extra, id: 'u', role: 'user' },
			{ content: 'ok', role: 'assistant' }
		] as DatabaseMessage[];

	it('takes the images of the last user message as base64 with their type', () => {
		const out = fyaiImages([
			...withExtra([
				{ base64Url: 'data:image/png;base64,QUJD', name: 'a.png', type: AttachmentType.IMAGE },
				{ content: 'x', name: 'f.txt', type: AttachmentType.TEXT }
			]),
			{ content: 'next', extra: [], id: 'u2', role: 'user' } as unknown as DatabaseMessage
		]);

		expect(out).toEqual([]);
		expect(
			fyaiImages(
				withExtra([
					{ base64Url: 'data:image/png;base64,QUJD', name: 'a.png', type: AttachmentType.IMAGE }
				])
			)
		).toEqual([{ data: 'QUJD', mediaType: 'image/png', name: 'a.png' }]);
	});

	it('leaves out an image that is not a data URL', () => {
		expect(
			fyaiImages(
				withExtra([{ base64Url: 'http://x/y.png', name: 'y', type: AttachmentType.IMAGE }])
			)
		).toEqual([]);
	});

	it('names the audio and video that fyai cannot take', () => {
		const out = fyaiUnsupportedAttachments(
			withExtra([
				{ name: 'a.mp3', type: AttachmentType.AUDIO },
				{ name: 'v.mp4', type: AttachmentType.VIDEO },
				{ name: 'i.png', type: AttachmentType.IMAGE }
			])
		);

		expect(out).toEqual(['a.mp3', 'v.mp4']);
	});
});
