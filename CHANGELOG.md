# Changelog

## Unreleased

### Fixed

- **A failed turn keeps its work.** An error in the tool loop no longer drops
  the whole turn: the steps up to the last complete tool round are stored. A
  tool call that returns no result gets a tool error, and the turn continues.
  The log of a fullscreen session shows the rows that report errors first.
- **A monitor ran for the limit that it was given.** A monitor can ask for 30
  minutes, but its command ran under the 10 minute ceiling of
  `shell/max_timeout_ms` and ended early, which the model could not tell from the
  limit it had asked for. The ceiling no longer applies to a monitor, and the end
  of a monitor that reached its limit names the limit.

## 0.4 - 2026-10-22

### Added

- **Attachments and image input.** Attach images and text files to a message
  with `@PATH` (completed on Tab), `/attach`, `/image add`, `/image paste`
  (clipboard helper), or `--image`. Each provider grammar carries images; an
  attachment shows as a bold reference row on the card. A pinned root refuses
  attachments. Exports carry image bytes as `!!binary` and imports restore
  them. See `doc/media.md`.
- **Claude Agent SDK compatibility.** `fyai` serves the SDK protocol with
  streaming, forks, structured output, hooks, permissions, and per-invocation
  MCP servers. A persona can limit the tools of its agent, and a sub-agent
  relays its tool calls and steps to the parent.
- **ACP.** Editor protocol support for v1 and v2.
- **MCP.** Deferred discovery and resource access.
- **Web page and desktop app.** A chat page (imported from the llama.cpp web
  UI) served by a local bridge that streams `fyai` turns, plus a desktop
  window for Linux and macOS with the native static `fyai` bundled. CMake
  targets build and install the page and the app; CI builds the releases. The
  page takes its slash commands from the `schema` verb and lists only models
  that have a credential.
- **`settings` tool.** The model can read, select, and export the
  configuration and the catalogue, and propose changes for review. The user
  keeps or reverts them. Each configuration key carries an `x-fyai-model`
  access level (`hidden`, `read`, `review`, `write`).
- **`list` command** now covers live shells, sub-agents, waits, monitors, and
  questions.
- **Terminal UI.** A log of results with levels in a small panel that expands
  to a popup; a maximize button that gives a tile the whole page; a prompt
  mark and waiting lines while input is queued; `display/idle_poll_ms`.
- **Turn control.** A turn reports why it stopped and can stop at a cost; a
  turn can answer with structured output; `branch` can start a fresh session
  from a branch.
- **Sandbox cover.** A sandboxed tool hides the project arena in a mount namespace,
  so it can create files in the project root. `sandbox_cover` chooses how: a user
  namespace of the tool, a bubblewrap holder that the tool joins, or none. On Ubuntu
  24.04 and later, which restrict user namespaces, fyai says at the start what to do:
  `fyai sandbox apparmor | sudo tee /etc/apparmor.d/fyai` (a new command that writes
  an AppArmor profile for the binary that runs), or install bubblewrap with its AppArmor profile.
- A session that runs in a view applies the view to the project when it ends from
  an idle prompt and no path conflicts (`view/apply_on_exit`). A new session
  refuses to start while the view holds a change that the project does not have.
- `FYAI_CAST` records a terminal session; the mock provider is served by a
  hidden `fyai` verb.
- `patch` accepts a unified diff inside the Begin Patch envelope.
- `root` prints its handle as text.
- `reasoning` effort and summary accept `none`, which sends no field.

### Changed

- **Sandbox profiles.** `sandbox_profile` names a profile, and the profiles are
  data: the `sandbox_profiles` key of `config.yaml.sample` holds `dev` and
  `lockdown`, so a new arena stores them and `config show` lists them, and the
  key takes more (`extends`, `deny`, `allow`, `network`, `view`). Paths may use `{{hostname}}`, `{{os}}`,
  `{{arch}}` and `{{host_specific}}`. `dev` is the new default: the project,
  the toolchains and package caches of the user, and TCP to ports 80, 443 and
  9418 (git and registries). `dev-view` is `dev` with the session in a view. `/session profile [NAME]` lists or selects a
  profile and restarts the session; `/session dev` selects `dev`. A profile may
  carry `view: true`: the session then runs in a view of the project, and a
  switch to a profile without one applies the view to the project first and
  refuses on a conflict. PATH keeps
  only the directories that the sandbox grants reach.
- The warning that TCP or UDP egress remains open on an old kernel appears
  once for each process, not at each tool call.

- Configuration and catalogue paths escape `/` and `~` as `~1` and `~0`.
- Model changes persist and show effective YAML diffs; sourced catalogue
  changes are reviewed before commit.
- `api_url` is derived from the grammar when it names another grammar, and
  the grammar stays with the endpoint that speaks it.
- A verb that sends no model request no longer resolves the model; it starts
  faster and needs no credential. Large embedded documents load from a
  prebuilt image, and the embedded data is checked once at build time.
- A signed-out login counts as no login, and an interactive resume works
  without API credentials.
- The shell tool accepts `cmd` as the command and rejects a call without one.
- The shell tool runs bash where the system has it, and else `/bin/sh`, so the
  model meets one dialect on every host. `shell/shell` still chooses another.
- The mostly-static build is shared between hosts, Docker, and CI, and the
  glibc baseline is selected by architecture.

### Fixed

- `--version` printed a stale value because an ignored `.tarball-version` file
  overrode the git version, and a snapshot version string failed CMake's
  `project(VERSION)` check. CMake now keeps the full string for display.
- A closed shell no longer leaves a wait pending; a failed JSON-RPC write
  reports no output.
- A configuration value that a layer repeats is kept.
- A tool title row cannot be read past its end; a tile title that is cut keeps
  its text; a patch that does not parse gets a title row.
- Page slot ids no longer overflow the slot buffer, and skill path building
  checks lengths.
- Libcurl initialisation moves to the first handle.
- Build fails on a returned address of stack storage; `true` and `false` are
  `_Bool` in every translation unit.

### Documentation

New or updated: attachments, the SDK, ACP, MCP discovery, the settings tool,
declarative state, the web page and desktop app, build targets, the PTY
driver, `FYAI_CAST`, the mock provider, and the `web_fetch` design.
