# Textual export format

`fyai export` writes a branch as one Markdown document. The document contains
the provider-independent conversation and the history of the branch store. It omits
provider request IDs, tool-call IDs, timestamps, and stream data.

Export writes to standard output or `-o <file>`. Import reads from standard
input or `-i <file>`:

```sh
fyai export | ssh host fyai import
fyai export -o conversation.md
fyai import -i conversation.md
```

On export, `--branch`/`-b` selects the source. On import, it selects an empty
destination branch. Import without this option replaces the active branch.

Export also takes a reference to one entry of a ref log: `<branch>` or
`<branch>@{N}`. It writes the branch as it was at that entry, with the
history that leads to it. `fyai list reflog` shows the entries.

```sh
fyai export -o before.md 'main@{1}'
```

A `<branch>~N` reference names a turn and not a ref-log entry, thus export
refuses it.

## Directives

A directive starts with `<!-- meta:yaml` at column zero and ends with `-->` at
column zero. The content is one YAML mapping.

```md
<!-- meta:yaml
format: 2
kind: conversation
-->
```

Visible headings present the directive that precedes them. Headings do not
contain state.

The document uses these structural directives:

- `conversation` starts the document and specifies the format version.
- `publish` starts one branch reference-log entry.
- `turn` starts one stored turn.
- `message` contains one message role and is followed by its text.
- `tool_call` contains one tool name, its arguments, and its result.
- `compact` records a compaction operation.
- `store` contains the complete initial branch store.
- `store-update` contains a later change of the branch store.

Publish and turn directives preserve boundaries that cannot be derived from
messages. Import replays these boundaries in order.

## Branch store

The first publish contains a `store` directive with the branch store: the
configuration, the catalogue, the description and every other member. A later
publish can contain a `store-update` mapping. Each update key is a slash path
into the store. A configuration key is below `config/`, as `fyai config set`
names it:

```yaml
kind: store-update
store-update:
  config/temperature: 0.7
  config/display/tool_detail: full
  config/agent/timeout_ms: null
  description: the parser work
```

A null value removes the key. A sequence is one value and is replaced as a
whole.

Export omits `cwd`, `created`, `agent` and `import`. These members describe the
arena of the export, and import makes them again. A branch that has no
catalogue exports none. Import keeps the configuration and the catalogue of the
destination branch when the document holds none.

Import also reads format 1. There, `config` contains the complete initial
configuration and `config-update` a later change, with paths relative to the
configuration.

## Messages and tool calls

A message directive contains the role. The Markdown text after the directive
is the message content.

```md
<!-- meta:yaml
kind: message
role: user
-->
## User

Inspect the source.
```

A tool-call directive contains the arguments and the result:

```md
<!-- meta:yaml
kind: tool_call
tool: shell
arguments:
  command: rg -n TODO src
result: |
  src/main.c:10: TODO
-->
```

Canonical state stores a call and its result as separate messages. The export
joins them. It does not store a call ordinal or provider call ID. A diff or
merge can therefore move the complete call without changing an identifier.

An unanswered call has no `result` key. Parallel calls use separate
directives. Import creates new call IDs and restores each result in the next
stored turn.

## Attachments

A message that carries an image exports its text and one Markdown row for each
image, in the order the parts appear:

```md
## User

what is wrong in this screenshot?

![image: PNG 1024x768, 96 KiB](fyai-media:ab12...)
```

The row is for the reader. The alt text describes the image: type, pixel
size, and stored size; the link names it by digest.

The document carries the bytes too. The directive of such a message holds its
whole `content` sequence, the text parts and the image parts, and each image
part holds its bytes as `!!binary` base64, in lines of the width of the
directive:

```md
<!-- meta:yaml
kind: message
role: user
content:
- type: text
  text: what is wrong in this screenshot?
- type: image
  media_type: image/png
  digest: ab12...
  width: 1024
  height: 768
  bytes: 98304
  data: !!binary |
    iVBORw0KGgoAAAANSUhEUgAABAAAAAMACAYAAACHnrXM4/qRqL/W7YSbssng946lvNPqgZiv
    ...
  name: screenshot.png
-->
```

Import takes the content from the directive and not from the prose that follows
it. Each image part is made again from its bytes: the type, the size and the
digest must be those that the bytes give, a part without bytes is an error,
and the limits of `media/max_bytes` and `media/max_per_message` hold. The
document is therefore enough to restore the image in another arena, with no
access to the file it was read from. See `doc/media.md` for the canonical
part.

## Compaction

The export records a compaction operation and its instructions. It does not
store the provider output, because that output is bound to the provider and
session.

Import re-issues the operation with the current model and endpoint. Use
`--ignore-compact` to skip compaction markers. An import without a compaction
marker makes no provider request.

## Replay

`fyai replay` reads the active branch and re-issues its user prompts in order.
It starts a new chain with the current system prompt. It does not restore
assistant messages or tool calls; the model and tools produce new results from
the current environment.

Replay re-issues stored compactions. Use `--ignore-compact` to skip them. The
old conversation remains in the branch reference log.

## Payloads

Structured payloads are inside directives. They are not in fenced Markdown
blocks. YAML indents block scalars, so payload text cannot put the directive
terminator at column zero.

Only message text is outside a directive. The exporter escapes a directive
opener at column zero by adding one `x`:

| Message text | Exported text |
| --- | --- |
| `<!-- meta:yaml` | `<!-- x-meta:yaml` |
| `<!-- x-meta:yaml` | `<!-- xx-meta:yaml` |

The importer removes one `x`. This rule also escapes an already escaped
opener, so the conversion is reversible.

## Determinism

The export uses canonical content and stable ordering. It omits provider wire
data and generated call identifiers. Equivalent canonical state produces the
same document.
