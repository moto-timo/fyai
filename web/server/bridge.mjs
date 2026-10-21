#!/usr/bin/env node
// SPDX-License-Identifier: MIT
/*
 * fyai bridge: serve the web UI and expose fyai to it.
 *
 * The browser cannot start a process, so this program owns every fyai
 * process. Each chat turn runs `fyai claude-sdk` with the session of the
 * conversation and streams the protocol frames of the SDK to the page as
 * server-sent events. The bridge holds no conversation state: the session
 * ID is the conversation ID of the page, and fyai stores the turns.
 *
 * A one-shot request (`/v1/chat/completions`) is not served: the page uses
 * `/api/fyai/chat`, and a second path would start sessions that nobody
 * reads.
 */

import {
	catalogueModelName,
	fencedOutput,
	findCatalogueModel,
	parseSlashCommand,
	providerKeyEnvName,
	sessionIdFor,
	slashCommandArgs,
	unknownCommandMessage
} from './protocol.mjs';
import { spawn } from 'node:child_process';
import { createReadStream } from 'node:fs';
import { stat } from 'node:fs/promises';
import { createServer } from 'node:http';
import { dirname, extname, join, normalize, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));

/* ------------------------------------------------------------------ config */

function parseArgs(argv) {
	const opts = {};

	for (let i = 0; i < argv.length; i++) {
		const arg = argv[i];

		if (!arg.startsWith('--')) continue;

		const name = arg.slice(2);
		const value = argv[i + 1] && !argv[i + 1].startsWith('--') ? argv[++i] : 'true';

		opts[name] = value;
	}

	return opts;
}

const argv = parseArgs(process.argv.slice(2));
const env = process.env;
const config = {
	bin: argv.bin ?? env.FYAI_BIN ?? 'fyai',
	cwd: resolve(argv.cwd ?? env.FYAI_BRIDGE_CWD ?? process.cwd()),
	extraArgs: (argv['extra-arg'] ?? env.FYAI_BRIDGE_ARGS ?? '').split(/\s+/).filter(Boolean),
	host: argv.host ?? env.FYAI_BRIDGE_HOST ?? '127.0.0.1',
	model: argv.model ?? env.FYAI_BRIDGE_MODEL ?? '',
	/*
	 * The program that started this one, when it wants the bridge to stop with
	 * it. The desktop app sets it, so closing the window leaves no bridge
	 * behind even if the app is killed instead of quitting.
	 */
	parentPid: Number(argv['parent-pid'] ?? env.FYAI_BRIDGE_PARENT_PID ?? 0),
	permissionMode: argv['permission-mode'] ?? env.FYAI_PERMISSION_MODE ?? 'bypassPermissions',
	port: Number(argv.port ?? env.FYAI_BRIDGE_PORT ?? 9331),
	staticDir: resolve(argv.static ?? env.FYAI_BRIDGE_STATIC ?? join(HERE, '..', 'dist')),
	/* A turn that runs longer than this is stopped. 0 disables the limit. */
	turnTimeoutMs: Number(argv['turn-timeout-ms'] ?? env.FYAI_BRIDGE_TURN_TIMEOUT_MS ?? 0),
	verbose: (argv.verbose ?? env.FYAI_BRIDGE_VERBOSE ?? '') === 'true'
};
const SDKMODES = new Set(['default', 'acceptEdits', 'bypassPermissions', 'dontAsk', 'auto']);

function log(...args) {
	process.stderr.write(`fyai-bridge: ${args.join(' ')}\n`);
}

/* ------------------------------------------------------------- life cycle */

/*
 * Every fyai process this program started and has not seen stop. A bridge that
 * is told to stop, or whose parent goes away, ends them too: otherwise the
 * turns of a closed window keep running their tools with nobody to read the
 * result.
 */
const children = new Set();

let stopping = false;
/** Set once the HTTP server exists, so a shutdown can stop listening. */
let server = null;

function trackChild(child) {
	children.add(child);
	child.on('close', () => children.delete(child));

	return child;
}

/** Stop the children, then this process. */
function shutdown(reason, code = 0) {
	if (stopping) return;

	stopping = true;

	if (reason) log(`stopping: ${reason}`);

	for (const child of children) {
		try {
			child.kill('SIGTERM');
		} catch {
			/* It ended between the loop and the signal. */
		}
	}

	/*
	 * A child that ignores SIGTERM must not hold the port open. The grace
	 * period keeps a normal shutdown from landing a signal on a dying pid.
	 */
	const timer = setTimeout(() => {
		for (const child of children) {
			try {
				child.kill('SIGKILL');
			} catch {
				/* Already gone. */
			}
		}

		process.exit(code);
	}, 2000);

	timer.unref();

	if (server) server.close(() => process.exit(code));
	else process.exit(code);
}

for (const signal of ['SIGINT', 'SIGTERM', 'SIGHUP']) {
	process.on(signal, () => shutdown(signal));
}

/**
 * The parent that asked this bridge to die with it. A parent that is gone
 * cannot tell its child, so the child looks: a signal that fails with ESRCH
 * means the process is no longer there.
 */
function watchParent(pid) {
	if (!pid || pid === process.pid) return;

	/*
	 * A parent that dies closes its end of the pipe. That is immediate,
	 * where the check below can only notice within a second, and it also
	 * covers a pid that another process has reused.
	 */
	process.stdin.on('end', () => shutdown('the parent closed its end'));
	process.stdin.on('close', () => shutdown('the parent closed its end'));
	process.stdin.resume();
	process.stdin.unref?.();

	const alive = () => {
		try {
			process.kill(pid, 0);

			return true;
		} catch (error) {
			return error.code === 'EPERM';
		}
	};

	if (!alive()) {
		shutdown('the parent process is gone');

		return;
	}

	const timer = setInterval(() => {
		if (!alive()) shutdown('the parent process is gone');
	}, 1000);

	timer.unref();
}

/* ------------------------------------------------------------------- utils */

const MIME = {
	'.css': 'text/css; charset=utf-8',
	'.html': 'text/html; charset=utf-8',
	'.ico': 'image/x-icon',
	'.js': 'text/javascript; charset=utf-8',
	'.json': 'application/json; charset=utf-8',
	'.map': 'application/json; charset=utf-8',
	'.png': 'image/png',
	'.svg': 'image/svg+xml',
	'.ttf': 'font/ttf',
	'.wasm': 'application/wasm',
	'.webmanifest': 'application/manifest+json',
	'.woff': 'font/woff',
	'.woff2': 'font/woff2'
};

function sendJson(res, status, value) {
	const body = JSON.stringify(value);

	res.writeHead(status, {
		'access-control-allow-origin': '*',
		'cache-control': 'no-store',
		'content-length': Buffer.byteLength(body),
		'content-type': 'application/json; charset=utf-8'
	});
	res.end(body);
}

function sendError(res, status, message) {
	sendJson(res, status, { error: { message, type: 'fyai_bridge_error' } });
}

function readBody(req, limit = 32 * 1024 * 1024) {
	return new Promise((resolvePromise, reject) => {
		const chunks = [];

		let size = 0;

		req.on('data', (chunk) => {
			size += chunk.length;

			if (size > limit) {
				reject(new Error('request body is too large'));
				req.destroy();

				return;
			}

			chunks.push(chunk);
		});
		req.on('end', () => resolvePromise(Buffer.concat(chunks).toString('utf8')));
		req.on('error', reject);
	});
}

/* --------------------------------------------------------------------- SSE */

class EventStream {
	constructor(req, res) {
		this.closed = false;
		res.writeHead(200, {
			'access-control-allow-origin': '*',
			'cache-control': 'no-cache, no-transform',
			connection: 'keep-alive',
			'content-type': 'text/event-stream; charset=utf-8',
			'x-accel-buffering': 'no'
		});
		res.flushHeaders?.();
		this.res = res;
		this.req = req;
		this.ping = setInterval(() => this.write(': ping\n\n'), 15000);
		this.ping.unref?.();
		res.on('close', () => {
			this.closed = true;
			clearInterval(this.ping);
		});
	}

	end() {
		clearInterval(this.ping);

		if (!this.res.writableEnded) this.res.end();
	}

	send(frame) {
		this.write(`data: ${JSON.stringify(frame)}\n\n`);
	}

	write(chunk) {
		if (this.closed || this.res.writableEnded) return;

		this.res.write(chunk);
	}
}

/* --------------------------------------------------------------- the turn */

/*
 * Start one `fyai claude-sdk` process for one turn. The caller writes the
 * user frame, receives each protocol frame through `onFrame`, and owns the
 * process through the returned handle. stdin stays open until the `result`
 * frame arrives, because fyai reads standard input until it closes.
 */
function spawnTurn(options) {
	const {
		env = process.env,
		fresh = false,
		model = '',
		onExit = () => {},
		onFrame = () => {},
		permissionMode = config.permissionMode,
		prompt = '',
		sessionId,
		tools
	} = options;
	const mode = SDKMODES.has(permissionMode) ? permissionMode : config.permissionMode;
	/*
	 * Global options come before the command: fyai reads them there and
	 * rejects them after it.
	 */
	const globals = [...config.extraArgs];
	const args = [
		...globals,
		'claude-sdk',
		'--input-format',
		'stream-json',
		'--output-format',
		'stream-json',
		'--verbose',
		'--include-partial-messages',
		'--permission-mode',
		mode,
		fresh ? '--session-id' : '--resume',
		sessionId
	];

	if (model) args.push('--model', model);

	if (tools !== undefined) args.push('--tools', tools);

	if (config.verbose) {
		log('spawn', config.bin, args.join(' '));
	}

	const child = trackChild(
		spawn(config.bin, args, {
			cwd: config.cwd,
			env,
			stdio: ['pipe', 'pipe', 'pipe']
		})
	);
	const summary = {
		code: null,
		frames: 0,
		sawInit: false,
		sawResult: false,
		signal: null,
		stderr: ''
	};

	let stdout = '';
	let killed = false;
	let timer = null;

	const kill = (signal = 'SIGTERM') => {
		if (child.exitCode !== null || child.signalCode !== null) return;

		killed = true;
		child.kill(signal);

		setTimeout(() => {
			if (child.exitCode === null && child.signalCode === null) child.kill('SIGKILL');
		}, 3000).unref?.();
	};

	child.stdout.setEncoding('utf8');
	child.stdout.on('data', (chunk) => {
		stdout += chunk;

		let nl;

		while ((nl = stdout.indexOf('\n')) >= 0) {
			const line = stdout.slice(0, nl).trim();

			stdout = stdout.slice(nl + 1);

			if (!line) continue;

			let frame;

			try {
				frame = JSON.parse(line);
			} catch {
				summary.stderr += `unparsable frame: ${line}\n`;

				continue;
			}

			summary.frames++;

			if (frame.type === 'system' && frame.subtype === 'init') summary.sawInit = true;

			if (frame.type === 'result') summary.sawResult = true;

			onFrame(frame);

			/*
			 * fyai reads standard input until it closes. Close it after the
			 * result so that the process ends with its turn.
			 */
			if (frame.type === 'result' && child.stdin.writable) child.stdin.end();
		}
	});

	child.stderr.setEncoding('utf8');
	child.stderr.on('data', (chunk) => {
		summary.stderr = (summary.stderr + chunk).slice(-65536);
	});

	const done = new Promise((resolveDone) => {
		child.on('error', (error) => {
			summary.stderr += `${error.message}\n`;
			summary.code = -1;
			resolveDone(summary);
		});
		child.on('close', (code, signal) => {
			clearTimeout(timer);
			summary.code = code;
			summary.signal = signal;
			summary.killed = killed;
			onExit(summary);
			resolveDone(summary);
		});
	});

	if (config.turnTimeoutMs > 0) {
		timer = setTimeout(() => {
			summary.timedOut = true;
			kill();
		}, config.turnTimeoutMs);
		timer.unref?.();
	}

	if (prompt) {
		const frame = {
			message: { content: [{ text: prompt, type: 'text' }], role: 'user' },
			type: 'user'
		};

		child.stdin.write(`${JSON.stringify(frame)}\n`);
	}

	child.stdin.on('error', () => {
		/* The exit report says what happened; a broken pipe has no cause. */
	});

	return { child, done, kill, summary };
}

/* ---------------------------------------------------------------- models */

let catalogue = { at: 0, models: [] };

/* The provider of each model, as the catalogue resolves it. */
const providers = new Map();
/*
 * fyai has no load step: any model of the catalogue answers a turn. The page
 * asks for a llama.cpp router, where a model is loaded before it is used, so
 * every model is reported as loaded and a load or unload only changes what
 * this map says. The status feed then tells the page about the change.
 */
const modelStatus = new Map();
const statusFeeds = new Set();

function statusOf(name) {
	return modelStatus.get(name) ?? 'loaded';
}

/** Tell every open /models/sse reader about a status change. */
function announceModelStatus(name, status) {
	for (const feed of statusFeeds) {
		if (feed.closed) {
			statusFeeds.delete(feed);

			continue;
		}

		feed.send({ data: { status }, event: 'status_change', model: name });
	}
}

/**
 * Runs one slash command on the session branch and returns its output. The
 * verb writes its own result; this program only forwards it.
 */
async function runSlashCommand(sessionId, command, model, env = process.env) {
	const args = slashCommandArgs(sessionId, command, model, config.extraArgs);

	if (!args) return { ok: false, text: unknownCommandMessage(command.name) };

	const res = await runCapture(config.bin, args, 120000, env);
	const text = (res.out || res.err || '').trim();

	if (res.code === 0) return { ok: true, text };

	return { ok: false, text: text || `/${command.name} failed with status ${res.code}` };
}

function runCapture(bin, args, timeoutMs = 10000, env = process.env) {
	return new Promise((resolvePromise) => {
		const child = trackChild(spawn(bin, args, { cwd: config.cwd, env }));

		let out = '';
		let err = '';

		const timer = setTimeout(() => child.kill('SIGTERM'), timeoutMs);

		child.stdout.setEncoding('utf8');
		child.stderr.setEncoding('utf8');
		child.stdout.on('data', (chunk) => (out += chunk));
		child.stderr.on('data', (chunk) => (err += chunk));
		child.on('error', () => {
			clearTimeout(timer);
			resolvePromise({ code: -1, err: 'cannot run ' + bin, out: '' });
		});
		child.on('close', (code) => {
			clearTimeout(timer);
			resolvePromise({ code, err, out });
		});
	});
}

/**
 * The model of the project: what `fyai --get model` names, which may carry a
 * provider prefix. The catalogue spells it another way (`claude-haiku-5.5`
 * for `claude-haiku-5-5`), so this value is kept as fyai names it and put
 * first in the list: the page selects the first model it is offered.
 */
async function projectModel() {
	const res = await runCapture(config.bin, ['--get', 'model'], 20000);
	const line = res.out
		.split('\n')
		.map((row) => row.trim())
		.filter(Boolean)
		.pop();

	if (res.code !== 0 || !line) return config.model;

	/* A value of YAML flow is a quoted string or a plain one. */
	const quoted = /^'(.*)'$/.exec(line) ?? /^"(.*)"$/.exec(line);

	return (quoted ? quoted[1] : line) || config.model;
}

/**
 * The provider of a model, from `fyai model --output json`, which resolves it
 * through the catalogue. A model the catalogue does not know has none, and
 * the single API Key field then cannot name its variable.
 */
async function providerOfModel(model) {
	const cached = providers.get(model);

	if (cached && Date.now() - cached.at < 60000) return cached.name;

	const args = ['model', '--output', 'json'];
	const res = await runCapture(config.bin, model ? ['-m', model, ...args] : args, 20000);

	if (res.code !== 0) return '';

	try {
		const pos = res.out.lastIndexOf('{');
		const parsed = JSON.parse(res.out.slice(pos));
		const name = typeof parsed.provider === 'string' ? parsed.provider : '';

		providers.set(model, { at: Date.now(), name });

		return name;
	} catch {
		return '';
	}
}

/**
 * The environment of one fyai process: this program's, with a key per
 * provider. fyai reads `<PROVIDER>_API_KEY` for the provider it resolved, so
 * every key the page holds is offered and the right one is used.
 *
 * @param keys keys by provider name
 * @param apiKey the key of the API Key field, whose provider is the model's
 * @param model the model of the turn, which names that provider
 */
async function turnEnv(keys, apiKey, model) {
	const env = { ...process.env };

	for (const [provider, key] of Object.entries(keys ?? {})) {
		const name = providerKeyEnvName(provider);

		if (name && key) env[name] = String(key);
	}

	if (apiKey) {
		const provider = await providerOfModel(model);
		const name = providerKeyEnvName(provider);

		/* A named provider keeps its own key; the single field is the fallback. */
		if (name && !env[name]) env[name] = apiKey;
	}

	return env;
}

/** The catalogue of the project, with its own model first. */
async function listModels(force = false) {
	if (!force && Date.now() - catalogue.at < 30000) return catalogue.models;

	const [primary, res] = await Promise.all([
		projectModel(),
		runCapture(config.bin, ['catalog', 'list', '--output', 'json'], 20000)
	]);

	let listed = [];

	if (res.code === 0) {
		try {
			const parsed = JSON.parse(res.out);

			if (Array.isArray(parsed)) listed = parsed;
		} catch (error) {
			log('cannot parse the catalogue:', error.message);
		}
	} else {
		log('catalog list failed:', res.err.trim() || `status ${res.code}`);
	}

	const entries = listed
		.filter((model) => model && typeof model.name === 'string')
		.map((model) => ({
			context_window: Number(model.context_window) || 0,
			max_output_tokens: Number(model.max_output_tokens) || 0,
			name: model.name
		}));
	/*
	 * The model of the project comes first, and keeps the context window and
	 * the output limit the catalogue reports for it; it is usually the same
	 * entry under another spelling, which is then not listed twice. The name
	 * stays the one fyai used, so a turn sends exactly the model of the
	 * project and not another offering of the same name.
	 */
	const first = primary ? findCatalogueModel(entries, primary) : null;
	const models = primary
		? [
				{
					context_window: Number(first?.context_window) || 0,
					max_output_tokens: Number(first?.max_output_tokens) || 0,
					name: primary,
					primary: true
				}
			]
		: [];

	for (const entry of entries) {
		if (first && entry.name === first.name) continue;

		models.push(entry);
	}

	catalogue = { at: Date.now(), models };

	return catalogue.models;
}

function modelsPayload(models) {
	return {
		data: models.map((m) => ({
			context_length: m.context_window,
			created: 0,
			id: m.name,
			in_cache: true,
			name: m.name,
			object: 'model',
			owned_by: 'fyai',
			path: '',
			status: { args: [], value: statusOf(m.name) }
		})),
		models: models.map((m) => ({
			capabilities: [],
			description: m.context_window ? `context ${m.context_window}` : '',
			model: m.name,
			name: m.name
		})),
		object: 'list'
	};
}

/**
 * The props of one model. The page asks for the model it is about to use, so
 * the context window and the name are the ones of that model; the project
 * model answers when no model is named.
 */
function propsPayload(requested = '') {
	/*
	 * The model of the project is the one the page starts with. A catalogue
	 * entry for it supplies the context window when the catalogue knows the
	 * same name.
	 */
	const model = requested || (catalogue.models.find((m) => m.primary)?.name ?? config.model);
	const known = catalogue.models.find((m) => m.name === model);

	return {
		build_info: 'fyai bridge',
		chat_template: '',
		default_generation_settings: {
			id: 0,
			id_task: 0,
			is_processing: false,
			n_ctx: known?.context_window || 131072,
			params: {
				dry_allowed_length: 2,
				dry_base: 1.75,
				dry_multiplier: 0,
				dry_penalty_last_n: -1,
				dry_sequence_breakers: [],
				dynatemp_exponent: 1,
				dynatemp_range: 0,
				frequency_penalty: 0,
				grammar: '',
				grammar_lazy: false,
				grammar_triggers: [],
				ignore_eos: false,
				logit_bias: [],
				max_tokens: known?.max_output_tokens || -1,
				min_keep: 0,
				min_p: 0.05,
				mirostat: 0,
				mirostat_eta: 0.1,
				mirostat_tau: 5,
				n_discard: 0,
				n_keep: 0,
				n_predict: -1,
				n_probs: 0,
				presence_penalty: 0,
				preserved_tokens: [],
				repeat_last_n: 64,
				repeat_penalty: 1,
				seed: -1,
				stop: [],
				stream: true,
				temperature: 0.8,
				top_k: 40,
				top_n_sigma: -1,
				top_p: 0.95,
				typ_p: 1,
				xtc_probability: 0,
				xtc_threshold: 0.1
			},
			speculative: false
		},
		modalities: { audio: false, vision: false },
		model_alias: model,
		model_path: model || 'fyai',
		/*
		 * fyai serves many models and the page picks one per conversation, so
		 * the bridge answers as a router: that is what opens the model picker
		 * instead of the single-model manager, and what makes the page send the
		 * chosen model with each turn.
		 */
		role: 'router',
		total_slots: 1
	};
}

/* ----------------------------------------------------------------- routes */

async function handleChat(req, res) {
	let body;

	try {
		body = JSON.parse(await readBody(req));
	} catch (error) {
		sendError(res, 400, `cannot read the request: ${error.message}`);

		return;
	}

	const sessionId = sessionIdFor(body.conversationId);

	if (!sessionId) {
		sendError(res, 400, 'conversationId is required and must hold a letter or a digit');

		return;
	}

	const prompt = typeof body.prompt === 'string' ? body.prompt : '';
	const model = typeof body.model === 'string' && body.model ? body.model : config.model;
	const apiKey = typeof body.apiKey === 'string' ? body.apiKey.trim() : '';
	const providerKeys =
		body.providerKeys && typeof body.providerKeys === 'object' ? body.providerKeys : {};

	if (!prompt.trim()) {
		sendError(res, 400, 'prompt is required');

		return;
	}

	/* One environment for the command or the turn of this request. */
	const env = await turnEnv(providerKeys, apiKey, model);
	const stream = new EventStream(req, res);
	/*
	 * A slash command is not a turn: it runs a verb and shows what it wrote.
	 * The output is fenced so a table of the terminal keeps its columns.
	 */
	const command = parseSlashCommand(prompt);

	if (command) {
		const result = await runSlashCommand(sessionId, command, model, env);

		/*
		 * With a name, `/model` changes the model of the session branch, which
		 * the page would otherwise override with the model it has selected.
		 * The name in the frame lets the page select the same one and keep
		 * sending it; a name that the catalogue does not list cannot be shown
		 * there, and the answer says what will happen to the next turn.
		 */
		if (result.ok && command.name === 'model' && command.rest.length > 0) {
			const chosen = catalogueModelName(await listModels(), command.rest[0]);

			if (chosen) result.model = chosen;
			else
				result.text = `${result.text}\n\nThe catalogue does not list '${command.rest[0]}', so the page cannot show this model. Its next turn names the model selected there.`;
		}

		const frame = {
			ok: result.ok,
			subtype: 'command',
			text: fencedOutput(result),
			type: 'bridge'
		};

		if (result.model) frame.model = result.model;

		stream.send({ sessionId, subtype: 'start', type: 'bridge' });
		stream.send(frame);
		stream.send({ subtype: 'done', type: 'bridge' });
		stream.end();

		return;
	}

	let active = null;

	const abort = () => {
		if (active) active.kill();
	};

	req.on('close', abort);
	res.on('close', abort);

	stream.send({ sessionId, subtype: 'start', type: 'bridge' });

	const options = {
		/* The environment of this request, which carries the provider keys. */
		env,
		fresh: !!body.fresh,
		model,
		onExit: (summary) => {
			if (config.verbose)
				log('turn ended', JSON.stringify(summary.code), summary.stderr.slice(0, 200));
		},
		onFrame: (frame) => stream.send(frame),
		permissionMode:
			typeof body.permissionMode === 'string' ? body.permissionMode : config.permissionMode,
		prompt,
		sessionId
	};

	/*
	 * The process is spawned here, not through a helper, so the turn can be
	 * reachable by the abort handler while the frames arrive.
	 */
	let turns = 0;
	let summary;

	for (;;) {
		turns++;
		active = spawnTurn(options);
		summary = await active.done;

		/*
		 * A start and a resume differ in the one flag, and each is wrong for a
		 * session that the other one names: a new conversation has no session,
		 * and a turn retried after a failure has one already. fyai says which
		 * before it writes a frame; the other mode is then the right one.
		 */
		const noFrames = !summary.sawResult && summary.frames === 0;
		const missing =
			!options.fresh && turns === 1 && noFrames && /no session with ID/.test(summary.stderr);
		const exists =
			options.fresh && turns === 1 && noFrames && /exists already/.test(summary.stderr);

		if (!missing && !exists) break;

		options.fresh = missing;
		stream.send({ sessionId, subtype: missing ? 'fresh' : 'resume', type: 'bridge' });
	}

	active = null;

	if (summary.sawResult) {
		stream.send({ code: summary.code, subtype: 'done', type: 'bridge' });
	} else if (summary.killed) {
		stream.send({ subtype: 'cancelled', type: 'bridge' });
	} else {
		stream.send({
			code: summary.code,
			message: summary.stderr.trim() || 'fyai ended before the turn completed',
			subtype: 'error',
			type: 'bridge'
		});
	}

	stream.end();
	req.off('close', abort);
	res.off('close', abort);
}

async function serveStatic(req, res, pathname) {
	const rel = decodeURIComponent(pathname).replace(/^\/+/, '');
	const file = normalize(join(config.staticDir, rel || 'index.html'));

	if (!file.startsWith(config.staticDir + sep) && file !== config.staticDir) {
		sendError(res, 403, 'forbidden');

		return;
	}

	let target = file;

	try {
		const info = await stat(target);

		if (info.isDirectory()) target = join(target, 'index.html');
	} catch {
		/* A client route is served by the application shell. */
		target = join(config.staticDir, 'index.html');
	}

	try {
		const info = await stat(target);

		res.writeHead(200, {
			'cache-control': target.endsWith('index.html') ? 'no-cache' : 'public, max-age=3600',
			'content-length': info.size,
			'content-type': MIME[extname(target)] ?? 'application/octet-stream'
		});
		createReadStream(target).pipe(res);
	} catch {
		res.writeHead(503, { 'content-type': 'text/html; charset=utf-8' });
		res.end(
			'<!doctype html><title>fyai web UI</title><body style="font-family:system-ui;padding:2rem">' +
				'<h1>No build yet</h1><p>Run <code>npm install &amp;&amp; npm run build</code> in ' +
				'<code>web/</code>, or use <code>npm run dev</code> with the bridge running.</p>'
		);
	}
}

server = createServer(async (req, res) => {
	const url = new URL(req.url ?? '/', `http://${req.headers.host ?? 'localhost'}`);
	const pathname = url.pathname;

	if (config.verbose) log(req.method, pathname);

	try {
		if (req.method === 'OPTIONS') {
			res.writeHead(204, {
				'access-control-allow-headers': '*',
				'access-control-allow-methods': 'GET,POST,DELETE,OPTIONS',
				'access-control-allow-origin': '*'
			});
			res.end();

			return;
		}

		if (pathname === '/api/fyai/info') {
			const models = await listModels();

			sendJson(res, 200, {
				bin: config.bin,
				cwd: config.cwd,
				model: config.model,
				models,
				permissionMode: config.permissionMode,
				version: 1
			});

			return;
		}

		if (pathname === '/api/fyai/chat' && req.method === 'POST') {
			await handleChat(req, res);

			return;
		}

		if (pathname === '/v1/models') {
			sendJson(res, 200, modelsPayload(await listModels()));

			return;
		}

		/*
		 * The status feed of the router protocol. fyai needs no load, but the
		 * page follows the status of a model it unloaded or loaded, so the
		 * feed stays open and the handlers below write to it.
		 */
		if (pathname === '/models/sse') {
			const feed = new EventStream(req, res);

			statusFeeds.add(feed);
			res.on('close', () => statusFeeds.delete(feed));

			return;
		}

		if ((pathname === '/models/load' || pathname === '/models/unload') && req.method === 'POST') {
			let body = {};

			try {
				body = JSON.parse(await readBody(req));
			} catch {
				/* A request without a body names no model, and changes nothing. */
			}

			const name = typeof body.model === 'string' ? body.model : '';
			const status = pathname === '/models/load' ? 'loaded' : 'unloaded';

			if (name) {
				modelStatus.set(name, status);
				announceModelStatus(name, status);
			}

			sendJson(res, 200, { success: true });

			return;
		}

		if (pathname === '/props') {
			sendJson(res, 200, propsPayload(url.searchParams.get('model') ?? ''));

			return;
		}

		if (pathname === '/slots') {
			sendJson(res, 200, [{ id: 0, is_processing: false }]);

			return;
		}

		/*
		 * fyai runs its tools inside the turn, so the page starts none: an
		 * empty tool list keeps its picker empty instead of failing.
		 */
		if (pathname === '/tools') {
			sendJson(res, 200, []);

			return;
		}

		/* A turn is not replayed; an empty lookup keeps the resume probe quiet. */
		if (pathname === '/v1/streams/lookup') {
			sendJson(res, 200, []);

			return;
		}

		if (pathname === '/v1/chat/completions') {
			sendError(
				res,
				501,
				'this bridge serves /api/fyai/chat only: one fyai turn carries its tool calls'
			);

			return;
		}

		if (pathname.startsWith('/v1/stream')) {
			/* The page resumes a turn through fyai, not a replay buffer. */
			sendError(res, 404, 'no stream replay');

			return;
		}

		if (req.method !== 'GET' && req.method !== 'HEAD') {
			sendError(res, 405, 'method not allowed');

			return;
		}

		await serveStatic(req, res, pathname);
	} catch (error) {
		log('request failed:', error.stack ?? error.message);

		if (!res.headersSent) sendError(res, 500, error.message);
		else res.end();
	}
});

await listModels(true);
/*
 * A port that is taken is a common accident: another bridge, another window of
 * the app, or a development server. Say so in one line instead of letting the
 * socket error out of the process.
 */
server.on('error', (error) => {
	if (error.code === 'EADDRINUSE') {
		log(
			`port ${config.port} is in use by another program; start on another one ` +
				'with --port PORT, or with --port 0 for any free port'
		);
	} else {
		log(`cannot listen on ${config.host}:${config.port}: ${error.message}`);
	}

	process.exit(1);
});

server.listen(config.port, config.host, () => {
	/* Port 0 asks the system for a free port, so report the one it gave. */
	const address = server.address();
	const port = address && typeof address === 'object' ? address.port : config.port;

	config.port = port;
	log(`listening on http://${config.host}:${port}`);
	log(`fyai: ${config.bin}  cwd: ${config.cwd}  static: ${config.staticDir}`);
	log(`permission mode: ${config.permissionMode}`);
});

/* A bridge that the parent asked to stop with it must not outlive it. */
watchParent(config.parentPid);
