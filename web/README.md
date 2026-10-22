# fyai web UI

A browser chat interface for `fyai`, installable as a PWA. It is a fork of
the llama.cpp web UI (`tools/ui`), which supplies the chat shell, streaming
Markdown rendering, attachments, conversation store and the PWA assets. The
transport is replaced: instead of llama-server, the page talks to a local
bridge that runs `fyai claude-sdk` and streams the Claude Agent SDK protocol.

```text
browser (SvelteKit SPA, PWA)
        │  POST /api/fyai/chat      SSE of SDK frames
        ▼
bridge (web/server/bridge.mjs, Node, no dependencies)
        │  stdin/stdout JSON lines
        ▼
fyai claude-sdk  ──►  provider, tools, branches, arena
```

## Why a bridge

The browser cannot start a process and fyai has no daemon. The bridge is a
small program that you run yourself; it holds no conversation state. Each
turn starts one `fyai claude-sdk` process with the session of the
conversation, and fyai stores the turn in the branch `sdk/<conversation-id>`.
The session ID is the conversation ID of the page, so a turn only sends the
new message and the conversation survives a bridge restart.

## Choosing the model

fyai serves every model of the project catalogue, so the bridge answers the
page as a llama.cpp _router_: the picker at the composer lists the catalogue,
and the model a conversation picks travels with each turn. fyai has no load
step, so every model is reported as loaded.

- Only the models of a provider that has a key are listed
  (`fyai catalog list models --available`): the key is in the environment of
  the bridge, in the keyring, or behind a credential transport. When no
  provider has one, the whole catalogue is listed, so a key can be entered in
  the settings.
- The model of the project (`fyai --get model`) is the first row, and the one
  a new conversation starts with.
- `/model NAME` selects a model as well. Typed in full it is resolved by the
  page; when the prompt reaches fyai instead (pick the command from the list,
  or press Escape and then Enter), its output is shown as a message and the
  page takes the model it names.
- An answer records the model that produced it, so a conversation reopened
  from history returns the picker to that model.

## Requirements

- Node 20 or later.
- `fyai` on `PATH`, or `FYAI_BIN` set to its path.
- A provider and model configured for the project where fyai runs
  (`fyai model`, `fyai auth`, or the environment).

## Run

There are two scripts. Both take the fyai program from `--fyai PATH`, else
`$FYAI_BIN`, else `../build/fyai` (the project above this one), else `PATH`,
and both install the page's dependencies on the first run. Each run prints
the program it chose, so there is no doubt which fyai the page drives.

**`scripts/run.sh`** serves the built page: it builds when `dist/` is missing,
then starts the bridge.

```sh
cd web
./scripts/run.sh                     # http://127.0.0.1:9331
./scripts/run.sh --cwd ~/project     # another project for fyai
./scripts/run.sh --fyai /usr/local/bin/fyai
./scripts/run.sh --port 8080 --open  # another port, and a browser
./scripts/run.sh --build             # build the page again first
```

**`scripts/dev.sh`** is the edit loop: the bridge runs fyai and Vite serves
the page in front of it, forwarding `/api`, `/v1`, `/props` and `/slots`.
A change to a source file reloads the page and leaves the bridge alone.

```sh
cd web
./scripts/dev.sh                     # page on http://127.0.0.1:5173
./scripts/dev.sh --bridge-port 9440 --cwd ~/project
./scripts/dev.sh --fyai ~/work/fyai/build/fyai
```

Ctrl-C stops both. `npm start` and `npm run dev` run these scripts.

fyai works in the fyai project above `web/`. A copy of the page elsewhere
works in the directory the script was started from. A project with no
`.fyai/arena` gets a warning, and its model list is empty until `fyai init`
runs there.

A bridge started by hand has the same choice as `--bin`:

```sh
node server/bridge.mjs --bin /usr/local/bin/fyai --cwd ~/project
```

## Desktop app

`scripts/desktop.sh` opens the page in an Electron window. The bridge runs
as a child of the app, so nothing else has to be started:

```sh
cd web
./scripts/desktop.sh                     # the repo build, or fyai on PATH
./scripts/desktop.sh --fyai ~/bin/fyai   # another fyai
./scripts/desktop.sh --cwd ~/project     # another project
```

The app works in the project of fyai that it finds. The `FYAI_BRIDGE_CWD`
directory wins, then the directory the app was started in. A launcher starts
it in the bundle, in `/` or in the home directory, which is no place for an
arena, so the app then uses a directory of its own under the data directory of
the platform (`~/.config/fyai/project` on Linux, `~/Library/Application
Support/fyai/project` on macOS). A directory with no project gets one from
`fyai init`.

The window loads the built page, so run `npm run build` after you change it.
Electron needs Node 20 or later, and a graphical session.

The window asks the bridge for a free loopback port and reads the address it
reports, so a second window, a development bridge on 9331, or a bridge left
behind by an earlier run does not stop it. `FYAI_BRIDGE_PORT` pins the port
when something else, such as a browser, has to reach the same bridge.

The bridge stops with the app: the window tells it to quit, and it also
watches the app's process and its standard input, so an app that is killed
rather than closed still leaves nothing behind. A turn that is running when
that happens is stopped too, with the tools it started.

### Bundle it with fyai

`scripts/package.sh` writes a self-contained app to `dist-app/fyai-linux-<arch>/`.
With a standalone fyai in `fyai-bundle/fyai` it travels inside the bundle and
the app looks for it before the project build and `PATH`:

```sh
scripts/package.sh --bundle-fyai   # build a portable fyai first
scripts/package.sh                 # package the page as it stands
```

`scripts/bundle-fyai.sh` makes that binary. The default mode is `mostly`:
the fyai dependencies are static and only the host libc is needed, which every
glibc Linux has. `--mode musl` gives a fully static binary for a musl or an
older machine.

```sh
scripts/bundle-fyai.sh                 # docker build, mode mostly
scripts/bundle-fyai.sh --mode musl     # fully static
scripts/bundle-fyai.sh --from PATH     # copy a binary you built already
scripts/bundle-fyai.sh --check         # what a bundle would carry
```

The static modes build the fyai repository above `web/` in Docker; set
`FYAI_SRC` for another checkout.

## Build system

The fyai build has targets for this tree. They build nothing unless you ask
for them, and `FYAI_WEB=ON` makes the page part of a plain `ninja`:

| Target                 | What it does                          |
| ---------------------- | ------------------------------------- |
| `fyai-web-install`     | `npm ci`                              |
| `fyai-web`             | builds the page into `web/dist`       |
| `fyai-web-dev`         | the bridge and Vite, for editing      |
| `fyai-web-test`        | the unit tests                        |
| `fyai-web-turn`        | one turn against fyai's mock provider |
| `fyai-desktop`         | opens the desktop window              |
| `fyai-desktop-package` | `dist-app/`, with a bundled fyai      |

```sh
ninja -C build fyai-web            # build the page
ninja -C build fyai-web-test       # its tests
ctest --test-dir build -R fyai/web-test
cmake -S . -B build -DFYAI_WEB=ON  # or make it part of the build
```

The unit tests are registered with CTest only when `FYAI_WEB=ON`, and they
carry the label `web`, so a C-only run stays quick:
`ctest --test-dir build -LE web`.

With `FYAI_WEB=ON`, `make install` also installs the built page and the
bridge under `share/fyai/web`, and a `fyai-web` launcher in `bin`. The launcher
serves the page on `http://127.0.0.1:9331` and runs fyai in the current
directory; it needs only `node` at run time. The page needs node 20 or later
to build: with an older node, `FYAI_WEB=ON` leaves the page out and says so.
Build first and install second (`make && sudo make install`), so that `npm`
does not run as root. The desktop app is not installed.

## Bridge options

| Option              | Environment                   | Default             | Meaning                                 |
| ------------------- | ----------------------------- | ------------------- | --------------------------------------- |
| `--port`            | `FYAI_BRIDGE_PORT`            | `9331`              | listen port; 0 picks a free one         |
| `--host`            | `FYAI_BRIDGE_HOST`            | `127.0.0.1`         | listen address                          |
| `--bin`             | `FYAI_BIN`                    | `fyai`              | the fyai program (`--fyai` on a script) |
| `--cwd`             | `FYAI_BRIDGE_CWD`             | current directory   | project fyai works in                   |
| `--model`           | `FYAI_BRIDGE_MODEL`           |                     | default model of a session              |
| `--parent-pid`      | `FYAI_BRIDGE_PARENT_PID`      |                     | stop when this process stops            |
| `--permission-mode` | `FYAI_PERMISSION_MODE`        | `bypassPermissions` | how fyai decides on tool calls          |
| `--extra-arg`       | `FYAI_BRIDGE_ARGS`            |                     | extra arguments for `fyai claude-sdk`   |
| `--turn-timeout-ms` | `FYAI_BRIDGE_TURN_TIMEOUT_MS` | `0`                 | stop a turn after this; 0 is no limit   |
| `--static`          | `FYAI_BRIDGE_STATIC`          | `dist`              | built page to serve                     |
| `--verbose`         | `FYAI_BRIDGE_VERBOSE`         | off                 | log each process and request            |

The bridge listens on loopback only by default. It runs tools in the project
without asking, so do not bind it to a public address.

## How a turn becomes a page

| SDK frame                            | Shown as                                    |
| ------------------------------------ | ------------------------------------------- |
| `system`/`init`                      | the model name and the tool list            |
| `stream_event` `content_block_delta` | assistant text, appended live               |
| `assistant` with `text`              | the finished assistant message              |
| `assistant` with `tool_use`          | a tool call card                            |
| `user` with `tool_result`            | the result of that card                     |
| `result`                             | token counts, cost, and the end of the turn |

fyai runs the whole tool loop of a turn itself, so one HTTP response carries
several assistant messages. Each becomes its own chat message, and the tool
results sit between them, which is why the page does not run an agent loop of
its own.

## Provider keys

fyai reads a key from its own configuration, its environment, or the secret
store. The page adds a fourth source, in its settings:

- **API Key**: one key, for the provider of the model the conversation uses.
  The bridge asks fyai which provider that is (`fyai model --output json`) and
  sets `<PROVIDER>_API_KEY` for the turn.
- **Provider API keys**: one `provider = key` a line, for several providers at
  once. The provider name is the catalogue's, lower case:

  ```text
  anthropic = sk-ant-...
  openai = sk-...
  openrouter = sk-or-...
  ```

The bridge puts each key in the environment of the fyai process it starts, as
`<PROVIDER>_API_KEY`, so a conversation keeps working when you switch model to
another provider. A key already in the environment of the bridge is replaced
by the one from the page, and a provider the page does not name keeps
whatever fyai's own configuration or environment gives it.

The keys are stored in the browser (its local storage, on your machine) and
sent with each turn; the bridge keeps them for the length of the process it
starts and writes them nowhere. The settings field is a password field, so the
value is not shown on the screen.

## Slash commands

fyai's `claude-sdk` sends a `/` line to the model as text, except `/clear`.
This page therefore runs a command itself, as an fyai verb on the
conversation's session branch. It keeps no list of commands: the bridge reads
them from `fyai schema commands --output json` and serves them at
`/api/fyai/commands`, and the `/` picker of the page offers that list. A
command qualifies when it exists both as a verb and as a slash command and
needs no terminal. `/model` and `/cwd` keep the pickers of the page, and
`/clear` starts a new conversation, which is a new fyai session.

The output arrives as one fenced block in a message row, so a table keeps its
columns. A command runs as a child process with the words as argv; no shell
sees them. Anything else that starts with `/` is answered as unknown and does
not reach the model. An fyai without `schema` exports no commands, and the
page then serves none of them.

## What is not wired yet

- **Permissions**: `can_use_tool` round-trips are not shown. The bridge
  starts fyai with `--permission-mode bypassPermissions` by default; choose
  `default` to deny every call that no rule allows, or `acceptEdits`.
- **Images and audio**: the composer accepts them, but only text and text
  files reach the model. fyai media attachments (`@PATH`, `--image`) are not
  mapped yet.
- **Working directory per conversation**: the bridge runs every session in
  one directory, given by `--cwd`.
- **Regenerate and edit**: fyai appends to the stored session, so a
  regenerated answer continues the conversation instead of replacing the
  last turn. Use `/clear` or a new chat for a fresh session.
- **Resume after reload**: the page keeps its own conversation store; a turn
  in flight is not reattached.
- **Keys of an MCP server**: only provider keys travel from the page. An MCP
  server that needs a token takes it from the fyai configuration.

## Test a turn

These need no provider key: they run fyai against its mock provider.

`server/test-turn.sh` starts the mock and the bridge, then sends one turn and
prints the frames. A prompt of `-` starts them without a turn.

```sh
bash server/test-turn.sh chat_stream.json "hello" conv-1
bash server/test-turn.sh chat_stream.json -
```

`server/e2e.mjs` drives the built page in Chrome and waits for the answer:

```sh
node server/e2e.mjs http://127.0.0.1:9331 "hello" "Streaming hello from the mock."
```

Arguments come in pairs of what to type and the text that must appear, so a
conversation is two pairs:

```sh
node server/e2e.mjs http://127.0.0.1:9331 "first" "Alpha beta." "second" "Gamma."
```

`server/e2e-key.mjs` puts a key in the page's settings the way a person does
and checks that the turn is answered. It needs a real key and a real project:

```sh
KEY=sk-ant-... node server/e2e-key.mjs http://127.0.0.1:9331 1   # Provider API keys
KEY=sk-ant-... node server/e2e-key.mjs http://127.0.0.1:9331 0   # API Key
```

The unit tests cover the frame assembly, the prompt and the bridge's
decisions:

```sh
npx vitest --project=unit --run
```

## Layout

```text
web/
├── scripts/run.sh           build and serve the page
├── scripts/dev.sh           bridge and Vite, for editing
├── server/bridge.mjs        HTTP, SSE, fyai processes, catalogue
├── server/protocol.mjs      session IDs and slash commands
├── server/test-turn.sh      one turn against the mock provider
├── server/e2e.mjs           the built page in Chrome
├── src/lib/services/fyai.service.ts   turn transport and prompt
├── src/lib/services/fyai.turn.ts      frames to messages
├── src/lib/stores/chat/index.svelte.ts  maps frames to messages
└── src/…                    the fork of the llama.cpp UI
```

## Upstream

The interface is a fork of `tools/ui` in
[llama.cpp](https://github.com/ggml-org/llama.cpp), MIT licensed. See
`NOTICE.md`.
