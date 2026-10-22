// SPDX-License-Identifier: MIT
import { ChatFormCommandAction } from '$lib/enums';
import { getChatCommands } from '$lib/utils/chat-commands';
import { describe, expect, it } from 'vitest';

const base = { hasCwdTools: () => true, hasPrompts: () => true, showModelSelector: true };

describe('getChatCommands', () => {
	it('offers the commands that fyai reports after the commands of the page', () => {
		const commands = getChatCommands({
			...base,
			fyaiCommands: [{ description: '', name: 'stats', title: 'show the token use' }]
		});

		expect(commands.map((c) => c.name)).toEqual(['prompt', 'cwd', 'model', 'stats']);
		expect(commands[3]).toMatchObject({
			action: ChatFormCommandAction.FYAI,
			description: 'show the token use',
			disabled: false
		});
	});

	it('keeps the picker of the page for a command that both define', () => {
		const commands = getChatCommands({
			...base,
			fyaiCommands: [{ description: '', name: 'model', title: 'the model' }]
		});

		expect(commands.filter((c) => c.name === 'model')).toHaveLength(1);
	});

	it('has only its own commands when fyai reports none', () => {
		expect(getChatCommands(base)).toHaveLength(3);
	});
});
