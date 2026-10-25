// SPDX-License-Identifier: MIT
/*
 * The parts of the bridge that decide, with no process and no socket: the
 * branch of a conversation, the slash commands, and the block that their
 * output goes into. The test suite imports this module directly.
 */

/*
 * The slash commands of the page come from `fyai schema commands`, so the
 * page offers what the fyai it runs supports and keeps no list of its own.
 * fyai claude-sdk sends every other `/` line to the model as text, and
 * `/clear` there starts a session the page does not know, so each command
 * runs an fyai verb on the branch of the conversation instead. No shell sees the words:
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
 * @param {string} branch
 * @param {{ name: string, rest: string[] }} command
 * @param {string} model
 * @param {string[]} [extraArgs]
 * @param {{ name: string, aliases: string[] }[]} [commands] what fyai supports
 * @returns {string[] | null}
 */
export function slashCommandArgs(branch, command, model, extraArgs = [], commands = []) {
	const entry = findCommand(commands, command.name);

	if (!entry) return null;

	/*
	 * `/model` reads or writes the model of the session branch, so it is never
	 * told another one: with a name it stores that model, and without one it
	 * reports the model the branch already has.
	 */
	const setsModel = entry.name === 'model';
	/* Global options come before the command, as fyai reads them there. */
	const args = [...extraArgs, '--set', 'display/markdown=false', '--branch', branch];

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

/*
 * The settings of the page. The bridge keeps them in a file of the user, so
 * every window, project and browser sees the same ones. A key is not a
 * setting: fyai reads its keys from its own configuration and its environment,
 * and a key sent here is dropped, not stored.
 */

/** The settings that hold a secret, which the bridge never keeps. */
const SECRET_SETTINGS = new Set(['apiKey', 'providerApiKeys']);

/**
 * The settings in a request body, or null when the body holds none. Each value
 * is a string, a number or a boolean, as the page keeps them; a secret and any
 * other value are left out.
 *
 * @param {any} body `{config, userOverrides}`
 * @returns {{ config: Record<string, string | number | boolean>, userOverrides: string[] } | null}
 */
export function sanitizeSettings(body) {
	const config = body?.config;

	if (!config || typeof config !== 'object' || Array.isArray(config)) return null;

	/** @type {Record<string, string | number | boolean>} */
	const kept = {};

	for (const [key, value] of Object.entries(config)) {
		if (SECRET_SETTINGS.has(key)) continue;

		if (['string', 'number', 'boolean'].includes(typeof value)) kept[key] = value;
	}

	const overrides = Array.isArray(body.userOverrides)
		? body.userOverrides.filter(
				(/** @type {unknown} */ key) => typeof key === 'string' && !SECRET_SETTINGS.has(key)
			)
		: [];

	return { config: kept, userOverrides: overrides };
}

/**
 * The output of a verb as Markdown. The verb writes it as source when
 * `display/markdown` is off, tables included.
 *
 * @param {{ ok: boolean, text: string }} result
 * @returns {string}
 */
export function commandMarkdown(result) {
	const body = result.text || (result.ok ? 'done' : 'the command wrote nothing');

	return `${result.ok ? '' : '**The command failed.**\n\n'}${body}`;
}

/*
 * Conversations are branches, named as the CLI names them: a session starts
 * as `session/TIME` and any branch with an exchange is a conversation. fyai
 * holds the conversation, so the page lists, reads, renames and deletes the
 * branches through these verbs and keeps nothing of its own.
 */

/**
 * The conversations in the output of `fyai branch list --output json`: the
 * branches that hold an exchange, newest first. The time is in
 * microseconds there and in milliseconds here, as the page counts it.
 *
 * @param {any} list the parsed output
 * @returns {{ id: string, name: string, turns: number, model: string, updated: number }[]}
 */
export function conversationsFromBranches(list) {
	if (!Array.isArray(list)) return [];

	return list
		.filter((b) => typeof b?.branch === 'string' && Number(b.turns) > 0)
		.map((b) => ({
			id: b.branch,
			model: typeof b.model === 'string' && b.model !== '-' ? b.model : '',
			name: typeof b.description === 'string' ? b.description : '',
			turns: Number(b.turns) || 0,
			updated: Math.floor(Number(b.updated) / 1000) || 0
		}))
		.sort((a, b) => b.updated - a.updated);
}

/** The longest title that the page shows for a conversation. */
const TITLE_MAX = 80;

/**
 * A title for a branch that has no description: the first line of its first
 * user message. The CLI names a session by its time and sets no description,
 * so the page reads one from what was asked.
 *
 * @param {any[]} messages the stored messages of the branch
 * @returns {string} '' when no user message has text
 */
export function titleFromHistory(messages) {
	for (const message of messages) {
		if (message?.role !== 'user') continue;

		const line = messageTextOf(message)
			.split('\n')
			.find((l) => l.trim().length > 0);

		if (line) return line.trim().slice(0, TITLE_MAX);
	}

	return '';
}

/**
 * The messages in the output of `fyai history --output json`, which is one
 * stored message for each line. A line that is not an object is left out.
 *
 * @param {string} text
 * @returns {object[]}
 */
export function parseHistory(text) {
	const messages = [];

	for (const line of String(text ?? '').split('\n')) {
		if (!line.trim()) continue;

		try {
			const value = JSON.parse(line);

			if (value && typeof value === 'object' && !Array.isArray(value)) messages.push(value);
		} catch {
			/* A line that is not JSON is a diagnostic, not a message. */
		}
	}

	return messages;
}

/**
 * The branch of the conversation @id, which is the name of the branch, or ''
 * when the ID cannot be one. fyai checks the name again; this keeps a word
 * that fyai would read as an option, and a name with control bytes, out of
 * its argv.
 *
 * @param {unknown} id
 * @returns {string}
 */
export function conversationBranch(id) {
	const name = String(id ?? '');

	if (name.length > 200 || name.startsWith('-') || name.includes('..')) return '';

	return /^[A-Za-z0-9_][A-Za-z0-9_.:@/+~-]*$/.test(name) ? name : '';
}

/**
 * The name of a new session, in the form of the CLI: `session/` and the time
 * in UTC to the microsecond. The branch exists when its first exchange is
 * stored, as in the CLI.
 *
 * @param {number} [micros] microseconds since the epoch
 * @returns {string}
 */
export function newSessionBranch(
	micros = Math.floor((performance.timeOrigin + performance.now()) * 1000)
) {
	const date = new Date(Math.floor(micros / 1000));
	const stamp = date
		.toISOString()
		.replace(/[-:]/g, '')
		.replace(/\.\d+Z$/, '');

	return `session/${stamp}.${String(micros % 1000000).padStart(6, '0')}`;
}

/*
 * Edit and regenerate. The page keeps a tree of messages, and a turn can come
 * from any node of it, while a branch of fyai is one line. So each turn names
 * the last user message that it follows, the anchor, and the bridge cuts the
 * branch back to the end of that exchange before it runs the turn. The anchor
 * is the text of the message and the count of equal messages up to it, because
 * a prompt can be asked twice.
 */

/**
 * The text of a stored message: a string, or the text parts of a list.
 *
 * @param {any} message
 * @returns {string}
 */
export function messageTextOf(message) {
	const content = message?.content;

	if (typeof content === 'string') return content;

	if (!Array.isArray(content)) return '';

	return content.map((part) => (typeof part?.text === 'string' ? part.text : '')).join('');
}

/**
 * What to do to the branch so that it ends at the exchange of the anchor.
 *
 * - `none`: it ends there already, or the anchor is not in it, so there is
 *   nothing that can be cut;
 * - `delete`: the turn follows no user message, and the branch holds some, so
 *   the branch goes and the turn starts a new one;
 * - `reset`: cut back to `keep` messages, the ones before the next user
 *   message.
 *
 * @param {object[]} history the stored messages of the branch
 * @param {{ text: string, occurrence: number } | null} anchor
 * @returns {{ action: 'none' } | { action: 'delete' } | { action: 'reset', keep: number }}
 */
export function rewindPlan(history, anchor) {
	/** @type {number[]} */
	const users = [];

	history.forEach((message, index) => {
		if (/** @type {any} */ (message).role === 'user') users.push(index);
	});

	if (!anchor) return users.length ? { action: 'delete' } : { action: 'none' };

	const wanted = String(anchor.text ?? '').trim();
	const same = users.filter((index) => messageTextOf(history[index]).trim() === wanted);
	const at = same[(Number(anchor.occurrence) || 1) - 1];

	if (at === undefined) return { action: 'none' };

	const next = users.find((index) => index > at);

	return next === undefined ? { action: 'none' } : { action: 'reset', keep: next };
}

/*
 * Images. The turn carries each image as a block of the user message, as the
 * Claude Agent SDK sends it: {type: image, source: {type: base64, media_type,
 * data}}. fyai keeps the bytes with the message.
 */

/** The image types that fyai takes (`doc/media.md`). */
export const IMAGE_TYPES = new Set(['image/gif', 'image/jpeg', 'image/png', 'image/webp']);

/**
 * The images of a request, checked. Each is `{mediaType, data, name}` with the
 * data as base64 text.
 *
 * @param {unknown} images
 * @returns {{ images: { mediaType: string, data: string, name: string }[] } | { error: string }}
 */
export function checkImages(images) {
	if (images === undefined) return { images: [] };

	if (!Array.isArray(images)) return { error: 'images must be a list' };

	const checked = [];

	for (const image of images) {
		if (!IMAGE_TYPES.has(image?.mediaType))
			return {
				error: `an image of type '${image?.mediaType}' is not supported: use PNG, JPEG, GIF or WebP`
			};

		if (typeof image.data !== 'string' || !image.data || !/^[A-Za-z0-9+/]*={0,2}$/.test(image.data))
			return { error: 'the data of an image must be base64 text' };

		checked.push({
			data: image.data,
			mediaType: image.mediaType,
			name: typeof image.name === 'string' && image.name ? image.name : 'image'
		});
	}

	return { images: checked };
}

/**
 * The content of the user message of a turn: the text, when there is any, and
 * a block for each image.
 *
 * @param {string} prompt
 * @param {{ mediaType: string, data: string, name: string }[]} images
 */
export function userContent(prompt, images) {
	const content = [];

	if (prompt.trim()) content.push({ text: prompt, type: 'text' });

	for (const image of images)
		content.push({
			name: image.name,
			source: { data: image.data, media_type: image.mediaType, type: 'base64' },
			type: 'image'
		});

	return content;
}

/*
 * What the page learns about a model. The page reads the input types of a model
 * from the router form of /v1/models (`architecture.input_modalities`) and its
 * abilities from `capabilities`, and refuses an image for a model with no
 * `image` input, so the catalogue of fyai says both.
 */

/**
 * The input types of a model for the page: text, and the others that the page
 * has a kind of file for. A PDF is read as text by the page.
 *
 * @param {unknown} modalities the `modalities` of a catalogue entry
 * @returns {string[]}
 */
export function inputModalities(modalities) {
	const known = new Set(['audio', 'image', 'video']);
	const listed = Array.isArray(modalities) ? modalities.filter((m) => known.has(m)) : [];

	return ['text', ...listed];
}

/**
 * The abilities of a model as the page names them.
 *
 * @param {unknown} capabilities the `capabilities` of a catalogue entry
 * @returns {string[]}
 */
export function pageCapabilities(capabilities) {
	const names = { reasoning: 'reasoning', tool_calling: 'tools' };

	return Array.isArray(capabilities)
		? capabilities.map((c) => names[/** @type {keyof typeof names} */ (c)]).filter(Boolean)
		: [];
}
