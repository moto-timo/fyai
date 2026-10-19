# Attachments and image input

An attachment is binary data that a model reads as media rather than as text.
This document describes how fyai transports it, where the bytes live, and what
a message records. It is the design of the storage and of the wire part; the
rendering of an attachment in the terminal is a separate, later step.

## What is supported

Images today: PNG, JPEG, GIF, and WebP. The set is closed and stated in one
place, `enum fyai_media_type` (`src/fyai_media.h`). A model reads an
attachment as an image part only when its catalogue entry lists the image
modality; see *Capability* below.

Attachments are added explicitly. A typed line is text, whatever it names: a
path in the line is a path, not an upload. The two ways in are:

- `/image add PATH` and `/image paste`, or
- the `--image PATH` option of an invocation.

`/image list` shows what waits and `/image clear` drops it.

## Storage

The bytes are an arena value. An image part holds them as a binary string,
`data`, in the message that carries the image, so they live and are collected
with the conversation, and there is nothing beside the arena:

```text
<project>/.fyai/arena                the durable root, the image bytes included
```

An attachment reads the file once, copies its bytes into the builder of the
invocation, and waits in the context until the next user message takes it. The
publish of that message writes the bytes with the rest of it; no reader finds a
reference whose bytes are elsewhere, and a dropped attachment leaves nothing
behind. `media/max_bytes` bounds what one attachment adds to the arena.

`--root` reads one published state and writes nothing, so an attachment there
is refused with a cause: the next message would be a write.

A string that is mostly bytes that are not UTF-8 is still a string to libfyaml.
Where it is written as text, the bytes travel without loss: YAML output writes
it as `!!binary` base64 (`FYOPEF_BINARY_BASE64`), and JSON output escapes each
such byte as a lone surrogate `\uDC80`-`\uDCFF`. Both read back as the same
bytes.

## The canonical part

A message `content` is a string when it holds text only, as it always was. With
an attachment, it becomes a sequence of parts:

```yaml
role: user
content:
  - {type: text, text: "what is wrong in this screenshot?"}
  - {type: image, media_type: image/png, digest: "ab12...", width: 1024,
     height: 768, bytes: 98304, data: !!binary "iVBORw0KGgo...",
     name: "clipboard"}
```

- `data` is the bytes of the image.
- `digest` is the BLAKE3-256 digest of the bytes. It is the identity: two
  parts with the same digest hold the same bytes, and the transcript row names
  the image by it.
- `width`, `height`, and `bytes` are read once, from the header of the image,
  and stored beside the bytes so a reader can describe the image without
  decoding it. They are metadata, not identity, and they are not what the
  digest is computed over.
- `name` is what the user called it. It is provenance; nothing reads the
  filesystem again from it.
- `media_type` is the type of the bytes as they were read. A caller that
  states a type is checked against them: a mismatch is an error, not a retype,
  because the digest must name one interpretation of the bytes.

A reader that needs the text of a message takes it through
`fyai_media_text()`, and a reader that needs every part takes it through
`fyai_media_parts()`; neither walks `content` itself. This keeps the sequence
form in one place.

## The wire form

Each provider grammar carries the image in its own shape, derived at the
request boundary from the canonical part, exactly as tool calls are:

| Grammar | Image part |
| --- | --- |
| Responses | `{type: input_image, image_url: "data:image/png;base64,..."}` beside `{type: input_text, text: ...}` |
| Chat Completions | `{type: image_url, image_url: {url: "data:image/png;base64,..."}}` beside `{type: text, text: ...}` |
| Messages | `{type: image, source: {type: base64, media_type: image/png, data: ...}}` |

The bytes are encoded when the request is built, so a conversation that gained
an image on one grammar continues on another. Nothing of the wire form is
stored: the arena keeps the canonical part only. This is the
same rule the provider boundary follows for every other canonical item.

Tool results are less portable. Messages carries an image block inside a
`tool_result`, and Responses carries one in the content of a
`function_call_output`; a Chat Completions tool message is a string. A tool
that attached an image would therefore return the reference where the grammar
carries it, and a note in its place where it does not. No such tool exists yet:
this series attaches images to what the user sends.

## Capability

Image input is a property of the model. The catalogue lists `image` in the
model's `modalities` when the model accepts images.
`fyai_config_resolve_model()` derives `cfg->image_input_supported` from that
list. A model absent from the catalogue has no declared image support.
Each request builder encodes image parts for its grammar.

A request with an image fails before it is sent when the selected model has
no image modality. The diagnostic names the model. `/image add` reports the
same restriction when it attaches the image.

## Limits

| Key | Default | Meaning |
| --- | --- | --- |
| `media/max_bytes` | 4194304 | Bytes of one attachment. |
| `media/max_per_message` | 8 | Attachments of one message. |
| `media/clipboard_command` | empty | A program that writes image bytes to standard output, in place of the detected one. |
| `media/clipboard_timeout_ms` | 5000 | Time limit of that program. |

A file above the limit is refused with a cause that names the size and the
limit. Nothing is downscaled: resampling an image needs a codec, and that is a
decision of its own.

## The clipboard

No terminal escape reads a clipboard: OSC 52 writes one and cannot read it
back. An image therefore comes from a local helper, run in a child:

- Wayland: `wl-paste --type image/png` (then the other types),
- X11: `xclip -selection clipboard -t image/png -o`, else `xsel`,
- macOS: `pngpaste -`.

`media/clipboard_command` replaces the search. Otherwise each helper that this
system could have is tried in turn: one whose display variable is unset is
skipped, because it cannot work. The child is sanitized with
`fyai_env_sanitize()` like every other program fyai starts, and it is stopped
at the time limit. A failure reports what was tried and what each attempt did:
a helper that wrote nothing, one that wrote something that is not an image, and
one that overran the time limit are different causes, and one message names
every one of them.

A helper that writes more than `media/max_bytes` is refused when its output is
published, not while it runs: the capture buffers what the program writes. A
clipboard holds an image the user put there, so this is a bound on what is
stored rather than a bound on the memory of the read.

A pasted path is the second route. A terminal that offers an image on paste
usually inserts a path, and `/image add PATH` is the explicit way to take it.

## The transcript

The user card shows one row for each attachment, as a Markdown image whose alt
text describes it:

```markdown
![image: PNG 1024x768, 96 KiB](fyai-media:ab12...)
```

The renderer prints the alt text today, so the row reads as a summary. The
`fyai-media:` scheme is the one hook a later renderer resolves to bytes and
draws through the graphics protocol the terminal probe reports (kitty, iTerm2,
or sixel). Nothing else changes when that is added: the stored transcript
already holds the description and the digest.

The model never sees this string. It receives the native image part, and the
text of the message as the user typed it.

## The estimate

An attachment counts in the token estimate as its reference, like any other
part of a message. It is not counted as `width * height / 750`, the rough cost
of an image at high detail, so `/context` and compaction keep the meaning they
have today. A model that spends many tokens on an image therefore shows a
smaller estimate than the provider reports, and the provider's reported usage
remains the authoritative number.

## What this does not do

- It does not draw an attachment, in any backend. The row is Markdown with an
  alt text; the image itself is not fetched.
- It does not give a model a tool that attaches an image. The routes are the
  ones the user takes.
- It does not write a clipboard, and it does not read one through the
  terminal.
- It does not downscale, convert, or re-encode anything.
