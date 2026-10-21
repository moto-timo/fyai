// SPDX-License-Identifier: MIT
/*
 * The parts of the bridge that decide, with no process and no socket: the
 * session ID of a conversation, the slash commands, and the block that their
 * output goes into. The test suite imports this module directly.
 */

/** The branch prefix of a session, as `fyai claude-sdk` names it. */
export const SDK_BRANCH_PREFIX = 'sdk/';

/*
 * The slash commands of the page. fyai claude-sdk sends every other `/` line
 * to the model as text, and `/clear` there starts a session the page does not
 * know, so each command here runs an fyai verb on the session branch instead.
 * No shell sees the words: they become argv.
 */
export const SLASH_COMMANDS = new Map([
	['branch', { args: ['branch'], help: 'list the branches of the project' }],
	['compact', { args: ['compact'], help: 'summarize the conversation' }],
	['context', { args: ['context'], help: 'show the context fill' }],
	['help', { args: ['help'], help: 'describe the fyai commands' }],
	['history', { args: ['history'], help: 'show the conversation of the session' }],
	['model', { args: ['model'], help: 'show or select the model of the session' }],
	['stats', { args: ['stats'], help: 'show the token use and the cost' }],
	['todo', { args: ['todo'], help: 'show the todo list of the session' }]
]);

/**
 * The session ID of a conversation. fyai accepts only alphanumerics, '-' and
 * '_' in a session ID, so every other byte becomes an underscore. The same
 * conversation always maps to the same session.
 *
 * @param {unknown} conversationId
 * @returns {string | null}
 */
export function sessionIdFor(conversationId) {
	const id = String(conversationId ?? '')
		.replace(/[^0-9A-Za-z_-]/g, '_')
		.slice(0, 64);

	return id || null;
}

/**
 * `/name rest` of a prompt, or null when the prompt is not a command.
 *
 * @param {unknown} prompt
 * @returns {{ name: string, rest: string[] } | null}
 */
export function parseSlashCommand(prompt) {
	const trimmed = String(prompt ?? '').trim();

	if (!trimmed.startsWith('/')) return null;

	const [name, ...rest] = trimmed.slice(1).split(/\s+/);

	return { name: name.toLowerCase(), rest };
}

/**
 * The argv of one command: the fyai words of the entry, then the words the
 * user typed. A model that only reads the session is told the model, because
 * a session carries no model of its own; `model NAME` stores one.
 *
 * @param {string} sessionId
 * @param {{ name: string, rest: string[] }} command
 * @param {string} model
 * @param {string[]} [extraArgs]
 * @returns {string[] | null}
 */
export function slashCommandArgs(sessionId, command, model, extraArgs = []) {
	const entry = SLASH_COMMANDS.get(command.name);

	if (!entry) return null;

	const setsModel = command.name === 'model' && command.rest.length > 0;
	/* Global options come before the command, as fyai reads them there. */
	const args = [...extraArgs, '--branch', `${SDK_BRANCH_PREFIX}${sessionId}`];

	if (model && !setsModel) args.push('--model', model);

	args.push(...entry.args, ...command.rest);

	return args;
}

/**
 * The message of an unknown command, naming what the page serves.
 *
 * @param {string} name
 * @returns {string}
 */
export function unknownCommandMessage(name) {
	const names = [...SLASH_COMMANDS.keys()].map((command) => `/${command}`).join(', ');

	return `unknown command /${name}; this page serves ${names}`;
}

/**
 * The environment name of a provider's key, as fyai reads it: the provider
 * name upper-cased, with each character that is not alphanumeric replaced by
 * '_', and `_API_KEY` after it. `anthropic` gives `ANTHROPIC_API_KEY` and
 * `open-router` gives `OPEN_ROUTER_API_KEY`.
 *
 * @param {string} provider
 * @returns {string | null}
 */
export function providerKeyEnvName(provider) {
	const name = String(provider ?? '').trim();

	if (!name || name.length > 64 || !/^[A-Za-z0-9_.-]+$/.test(name)) return null;

	return `${name.toUpperCase().replace(/[^A-Z0-9]/g, '_')}_API_KEY`;
}

/**
 * The output of a verb in a fenced block. A command result is text of the
 * terminal, and a fence keeps its columns and stops its markup rendering.
 *
 * @param {{ ok: boolean, text: string }} result
 * @returns {string}
 */
export function fencedOutput(result) {
	const body = (result.text || (result.ok ? 'done' : 'the command wrote nothing')).replace(
		/```/g,
		"'''"
	);

	return `${result.ok ? '' : '**The command failed.**\n\n'}\`\`\`text\n${body}\n\`\`\``;
}
