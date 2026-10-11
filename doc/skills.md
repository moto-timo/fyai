# Skills

A skill is a packaged set of instructions for one kind of task: a workflow, a
checklist, or a convention of a project. The format is the Agent Skills format
that Claude Code reads: a `SKILL.md` file with a YAML front matter, and
optional supporting files beside it.

```markdown
---
name: review
description: Review the staged change against the conventions of the project.
argument-hint: "[path]"
context: fork
allowed-tools: Read, Bash(git:*)
---
Review the staged change in $ARGUMENTS. Read `skill:review/checklist.md` first.
```

## Storage

Skills are branch state, as the configuration is. The branch store holds them
in the member `skills`:

```text
store/skills/<name>: {frontmatter, body, files, executables, source, imported, edited, enabled}
```

- `frontmatter` is the front matter as written. `name` is set from the
  directory when the file does not give it.
- `body` is the Markdown after the front matter.
- `files` maps a relative path to the text of a supporting file.
- `executables` lists the files that the import found executable by their
  owner. A file written out from the store, by an export or to run, takes
  the executable bit from it.
- `source` is the path that the skill was imported from. It is provenance
  only: nothing reads the filesystem again.
- `imported` and `edited` are microsecond timestamps.
- `enabled` is `false` for a skill that `skill disable` disabled, and absent
  otherwise. It belongs to the branch, not to the SKILL.md: the front matter
  stays as its author wrote it, and an export leaves the state out.

A skill enters the store only through `skill import`, `skill new`, or
`skill edit`. fyai does not discover skills in the filesystem, so a
repository that holds a `SKILL.md` does not change what the model sees until
the user imports it.

Skills follow the configuration. A fresh `session/` branch takes the skills of
the branch that gives it its configuration. `branch create` and
`checkout -b` take them with the store of the start point. A branch that does
not exist yet takes the skills of the branch that `HEAD` names. A sub-agent
branch takes the skills of its parent, and an executed sub-agent child gets
them in its spawn state. A concurrent publish merges `skills` key by key, as it
merges any member of the store: two different changes of one skill are a
conflict that `branch/on_conflict` decides.

## Front matter

`data/skill.schema.yaml` checks the front matter at each ingestion point:
import, new, and edit. A key that the schema does not name is kept and has no
effect.

| Key | Effect |
| --- | --- |
| `name` | The name: lowercase letters, digits, and `-`, at most 64. |
| `description` | Required. The model chooses a skill on this text. |
| `when_to_use` | More text for the choice, shown after the description. |
| `argument-hint` | The arguments, shown in the listing and in `skill list`. |
| `disable-model-invocation` | True: the model does not see the skill. |
| `user-invocable` | False: `/NAME` does not run the skill. |
| `context` | `fork` runs the skill as a sub-agent. `inline` is the default. |
| `agent` | The persona (`agent/personas`) of a forked skill. |
| `model` | The model of a forked skill, resolved through the catalogue. |
| `allowed-tools` | The tools of a forked skill. |
| `isolated` | fyai: a forked skill runs on a private project view. |
| `background` | fyai: a forked skill starts without holding the turn. |
| `timeout` | fyai: the time limit of a forked skill, in milliseconds. |

`model` and `allowed-tools` apply only with `context: fork`. An import of an
inline skill that sets them reports a note.

## The skill tool

The `skill` tool is offered when the branch holds a skill that the model can
load. Its description lists each such skill with its description, its
`when_to_use`, and its `argument-hint`, sorted by name. The tool entry adapts
the description through the `describe` function of its registry entry.

- `{skill, args}` loads an inline skill. The result is the body with the
  arguments in place, the base directory of the skill, and the names of the
  supporting files.
- `{skill, file}` returns one supporting file. `file` can carry the prefix
  `skill:NAME/`.
- A forked skill runs as a call of the `agent` tool. The `expand` function of
  the registry entry makes that call. The scheduler runs it and the turn
  answers the original `skill` call with the report.

### Arguments

The body takes the arguments as Claude Code gives them:

- `$ARGUMENTS` is the whole argument text.
- `$ARGUMENTS[N]` and `$N` are word N, counted from 0. Quotes keep blanks in
  one word.
- `${CLAUDE_SKILL_DIR}` is the base directory of the skill (see Files at run
  time), or `skill:NAME` when the skill has no files or they cannot be
  written out.
- `${CLAUDE_SESSION_ID}` is the name of the branch.

A body that names no argument gets a closing line `ARGUMENTS: ...`.

### Forked skills

A forked skill is a fresh sub-agent named `skill-NAME-XXXXXX`, where the tag
comes from the id of the call, so two calls in one response do not collide.
It does not see the conversation of the parent. The parent passes the name
and the arguments of the skill, and the sub-agent loads the skill itself, so
it writes the files out where its own programs run.
`agent` selects its persona, and `model` overlays the model of that persona.

`allowed-tools` restricts the sub-agent. The names map to fyai tools:

| Claude Code | fyai |
| --- | --- |
| `Read` | `read_file` |
| `Write` | `write_file` |
| `Edit`, `MultiEdit` | `apply_patch` |
| `Bash`, `Glob`, `Grep`, `LS` | `shell` |
| `Task`, `Agent` | `agent` |
| `TodoWrite` | `todo_write` |
| `AskUserQuestion` | `ask_user` |
| `Skill` | `skill` |

A fyai tool name is accepted as it is. A pattern such as `Bash(git:*)` grants
the whole tool; fyai does not check the pattern. A name that maps to no tool
is left out with a note. `shell` brings `shell_input`, `shell_output`, and
`shell_close`, and every forked skill keeps `skill`, `ask_parent`, and `time`.
The sub-agent offers only these tools, and `fyai_execute_tool_call()` refuses
a call of any other tool.

A run that cannot start a sub-agent does not expand the call. The skill tool
then reports that the skill runs as a sub-agent.

## User invocation

A session line `/NAME ARGS` runs a skill that the user can invoke, when no
command of the session has the exact name NAME. `/skill exec NAME ARGS` runs
the skill whatever commands there are; it is the way to a skill whose name a
command takes. On the command line `fyai skill exec NAME ARGS` runs one turn
with the skill. A command keeps its prefix
match: `/NAME` that is only a prefix of a command still runs the command
unless a skill has exactly that name. The line is a user turn. The transcript
keeps the line as typed, and the model gets the loaded skill. A one-shot
prompt `fyai "/NAME ARGS"` does the same. A forked skill that the user runs
asks the model to call the `skill` tool.

The skills that `/NAME` runs are offered with the commands: Tab completes
`/NA` to `/NAME`, with the argument hint and the description of the skill,
and `help` lists them under Skills. `help NAME` describes a skill when no
command has the name. A disabled skill, or one with `user-invocable: false`,
is not offered.

## Commands

| Command | Effect |
| --- | --- |
| `skill list` | List the skills: arguments, context, who can invoke, files. |
| `skill show NAME [FILE]` | Show the front matter as YAML, the body as Markdown and the names of the files, or one supporting file. |
| `skill files NAME` | List the supporting files with their sizes and lines. |
| `skill enable NAME...`, `skill disable NAME...` | Let the skills run, or keep them stored and unused. |
| `skill exec NAME [ARGS]` | Run a skill as a turn, whatever command has its name. |
| `skill import PATH [--force]` | Import a SKILL.md alone, a skill directory with its files, or a directory of them. |
| `skill import PATH --into NAME [--as REL]` | Store one text file as a supporting file. |
| `skill import --claude SCOPE [--force]` | Import the skills and commands of Claude Code. |
| `skill new NAME` | Write a new skill in an editor. |
| `skill edit NAME [FILE]` | Edit the SKILL.md or a supporting file in an editor. |
| `skill export NAME DIR` | Write the SKILL.md and the files under DIR. |
| `skill export NAME DIR --file REL` | Write one supporting file as DIR/REL; DIR `-` writes it to standard output. |
| `skill remove NAME... [--file REL]` | Remove skills, or one supporting file. |

A path to a SKILL.md imports that file alone: its directory names the skill,
and the files beside it are not read, because a SKILL.md can stand in a
directory of other work. An import of the directory reads the text files
under it, to a depth of 8. It
leaves out hidden entries, symbolic links, and binary files. Limits: 256 KiB
for each text, 256 files, and 8 MiB for one skill. The document skills of
Claude Code hold about 60 files and 1.1 MB each, most of it XML schemas.

`skill new` and `skill edit` are asynchronous commands. A session runs the
editor in the work pane, or on the terminal with `display/editor: terminal`.
The edit is stored when the editor ends. A text that fails the check stays in
its file, and the error names the file. An edit cannot rename a skill: export,
edit, and import it again.

`skill export` does not replace a file that exists.

`skill show` renders the body as Markdown with each `$` outside code escaped,
because a skill names its arguments with `$` and the renderer would read
`$ARGUMENTS ... $0` as math. `--output json` and `--output yaml` give the
body as it is stored.

## Claude Code skills

`skill import --claude SCOPE` reads the places where Claude Code keeps skills.
It is an explicit import, as every other one is: fyai does not read these
places at any other time.

| Scope | Reads |
| --- | --- |
| `project` | `.claude/skills` and `.claude/commands` in the current directory. |
| `user` | `skills` and `commands` of `$CLAUDE_CONFIG_DIR`, else `~/.claude`, and the skills that claude.ai synced to `skills/synced/BUCKET`. |
| `plugins` | `skills` and `commands` of each plugin that `plugins/installed_plugins.json` lists. |
| `all` | The three, in that order. |

- A directory under `skills` that holds a `SKILL.md` is a skill. A loose
  Markdown file there is not, as Claude Code does not read one.
- Each Markdown file under `commands` is a skill named by its stem, because
  Claude Code runs a command file as a skill. A subdirectory groups commands
  and does not change their names.
- A plugin skill is named `PLUGIN-NAME`, as Claude Code names it
  `PLUGIN:NAME`; the store refuses `:` in a name.
- The first source of a name wins, so a project skill comes before a user
  skill of the same name. A skill that is stored already is kept, with a note,
  unless `--force` is given.
- A file that cannot be read, such as one whose front matter is not between
  two lines of `---` at its start, is skipped with a warning that says why.
  The other skills are imported. A failure to get a resource stops the import.
- A scope that holds no skill is an error. A scope whose skills are all stored
  already reports that it imported nothing new.

Plugin agents (`agents/*.md`) are not imported: they map to
`agent/personas`, not to skills.

## Files at run time

A skill that has supporting files is written out when it is loaded, so its
programs can run as the skill describes: `python scripts/check.py` is a path
relative to the directory of the skill, as in Claude Code and Codex.

- The first load in an invocation makes a private directory,
  `$TMPDIR/fyai-skills-XXXXXX` (`/tmp` without `$TMPDIR`), with
  `mkdtemp()`, mode 0700. Each skill goes into `NAME/` under it: its
  SKILL.md and its files, with the executable bits of the store.
- The loaded skill tells the model `Base directory for this skill: DIR`, and
  `${CLAUDE_SKILL_DIR}` is DIR. `skill … file` still reads a file without a
  shell.
- A skill that changes during the invocation is written again, to `NAME.2`
  and so on: a program of the old copy can still run.
- The directory belongs to the process that made it. The invocation removes
  it when it ends, and a tool child removes its own when it exits. A forked
  child forgets the directory of its parent and does not remove it. A
  process that is killed leaves its directory to the cleaning of `$TMPDIR`.
- The process that runs the programs writes the files: a view gives each
  sub-agent a `/tmp` of its own, which its parent does not see. A forked
  skill therefore loads in the sub-agent.
- No name is reused across invocations: a name that another user can guess
  in a shared `/tmp` would let them put a script there first.
- The sandbox grants `/tmp`, `/var/tmp` and `/dev/shm` to the shell, so a
  confined shell runs the scripts.
- No environment variable names the directory. A tool keeps only the
  variables of its allowlist, and the skills in use name their files by
  relative paths and `${CLAUDE_SKILL_DIR}`, which the body takes as text.
- A file that cannot be written is a warning. The skill still loads, its
  `${CLAUDE_SKILL_DIR}` is `skill:NAME`, and the model reads the files
  through the tool.

## Not supported

- Discovery of skills at run time. Import them explicitly.
- `!`command`` preprocessing of the body. A skill does not run a program
  before the model reads it.
- `model` and `allowed-tools` for an inline skill.
- A binary supporting file, such as a font: the import leaves it out with a
  note.
