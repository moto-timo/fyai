// SPDX-License-Identifier: MIT
/*
 * The parts of the bridge that decide, with no process and no socket: the
 * session ID of a conversation, the slash commands, and the block that their
 * output goes into. The test suite imports this module directly.
 */

/** The branch prefix of a session, as `fyai claude-sdk` names it. */
export const SDK_BRANCH_PREFIX = 'sdk/';

/*
 * The slash commands of the page come from `fyai schema commands`, so the
 * page offers what the fyai it runs supports and keeps no list of its own.
 * fyai claude-sdk sends every other `/` line to the model as text, and
 * `/clear` there starts a session the page does not know, so each command
 * runs an fyai verb on the session branch instead. No shell sees the words:
 * they become argv.
 */

/**
 * The commands that a line of the page can run, from the schema document.
 * The page runs a verb and shows what it wrote, so a command qualifies when
 * it exists as a verb and as a slash command and needs no terminal.
 *
 * @param {any} doc the document of `fyai schema commands --output json`
 * @returns {{ name: string, aliases: string[], title: string, description: string,
 *   arguments: object | null }[]}
 */
export function commandsFromSchema(doc) {
	/** @type {any[]} */
	const list = Array.isArray(doc?.commands) ? doc.commands : [];

	return list
		.filter(
			(entry) =>
				entry &&
				typeof entry.command === 'string' &&
				Array.isArray(entry.surfaces) &&
				entry.surfaces.includes('cli') &&
				entry.surfaces.includes('session') &&
				!(Array.isArray(entry.flags) && entry.flags.includes('interactive'))
		)
		.map((entry) => ({
			aliases: Array.isArray(entry.aliases) ? entry.aliases.map(String) : [],
			arguments: entry.arguments ?? null,
			description: String(entry.description ?? '').trim(),
			name: entry.command,
			title: String(entry.title ?? '')
		}));
}

/**
 * The command that a typed name refers to: its name or one of its aliases.
 *
 * @param {{ name: string, aliases: string[] }[]} commands
 * @param {string} name
 */
export function findCommand(commands, name) {
	return commands.find((entry) => entry.name === name || entry.aliases.includes(name)) ?? null;
}

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
 * @param {{ name: string, aliases: string[] }[]} [commands] what fyai supports
 * @returns {string[] | null}
 */
export function slashCommandArgs(sessionId, command, model, extraArgs = [], commands = []) {
	const entry = findCommand(commands, command.name);

	if (!entry) return null;

	/*
	 * `/model` reads or writes the model of the session branch, so it is never
	 * told another one: with a name it stores that model, and without one it
	 * reports the model the branch already has.
	 */
	const setsModel = entry.name === 'model';
	/* Global options come before the command, as fyai reads them there. */
	const args = [...extraArgs, '--branch', `${SDK_BRANCH_PREFIX}${sessionId}`];

	if (model && !setsModel) args.push('--model', model);

	args.push(entry.name, ...command.rest);

	return args;
}

/**
 * The message of an unknown command, naming what the page serves.
 *
 * @param {string} name
 * @param {{ name: string }[]} [commands]
 * @returns {string}
 */
export function unknownCommandMessage(name, commands = []) {
	const names = commands.map((command) => `/${command.name}`).join(', ');

	return names
		? `unknown command /${name}; this page serves ${names}`
		: `unknown command /${name}; this fyai exports no commands (fyai schema)`;
}

/**
 * A model name as it compares to another: the part after a provider prefix,
 * lower-cased, without the punctuation that fyai and the catalogue spell
 * differently (`claude-haiku-5-5` is `claude-haiku-5.5`). A `:tag` suffix is
 * kept, so `gpt-oss-120b` and `gpt-oss-120b:batch` stay apart.
 *
 * @param {unknown} name
 * @returns {string}
 */
function modelKey(name) {
	const text = String(name ?? '')
		.trim()
		.toLowerCase();
	const bare = text.slice(text.lastIndexOf('/') + 1);

	return bare.replace(/[^a-z0-9:]/g, '');
}

/**
 * The catalogue entry that a name refers to, or null. fyai names a model the
 * way its provider does, and may put the provider in front of it
 * (`anthropic/claude-haiku-5-5`), where the catalogue uses the name of the
 * model (`claude-haiku-5.5`).
 *
 * @param {{ name: string }[]} models
 * @param {unknown} name
 * @returns {{ name: string } | null}
 */
export function findCatalogueModel(models, name) {
	const wanted = String(name ?? '').trim();

	if (!wanted) return null;

	const exact = models.find((model) => model.name === wanted);

	if (exact) return exact;

	const bare = wanted.slice(wanted.lastIndexOf('/') + 1);
	const listed = models.find((model) => model.name === bare);

	if (listed) return listed;

	const key = modelKey(wanted);

	if (!key) return null;

	return models.find((model) => modelKey(model.name) === key) ?? null;
}

/**
 * The catalogue name of a model that a `/model` argument names, or '' when
 * the catalogue has no such model.
 *
 * @param {{ name: string }[]} models
 * @param {unknown} name
 * @returns {string}
 */
export function catalogueModelName(models, name) {
	return findCatalogueModel(models, name)?.name ?? '';
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
