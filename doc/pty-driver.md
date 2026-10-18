# The PTY driver

The PTY driver is the hidden command `fyai __pty-driver`. A functional case
uses it to run a program on a pseudo-terminal. The driver plays the terminal
for the program. It types the keys of a script and it waits for a state of the
window between two keys. It never waits for a time.

```sh
fyai __pty-driver [--env NAME=VALUE]... SCRIPT OUTPUT PROGRAM [ARG...]
```

The driver writes all the bytes that the program sent to the file OUTPUT. It
writes the file also when a step fails. The driver returns 0 when each step
passed and the program ended as the script says. Otherwise it reports the
cause and returns a non-zero status.

`--env` sets a variable in the environment of the program only. The driver
keeps its own environment. A case that sets `FYAI_TRACE` uses this option, so
the trace does not count the driver as a start of the program.

The shell function `pty_run OUTPUT PROGRAM [ARG...]` of `tests/harness.sh` runs
the driver. It reads the script from standard input:

```sh
pty_run "$TEST_DIR/pty.out" "$FYAI_BIN" -k test-key -i <<'PTY'
rows: 30
cols: 100
steps:
  - type: hello
  - wait: Streaming hello from the mock.
    timeout: session
PTY
```

## The terminal

The driver answers the queries of the program from a terminal model:

- the cursor position (`CSI 6 n`);
- the device attributes (`CSI c`), which end the probe that fyai makes at
  start; and
- the background (`OSC 11`), only when the script sets `background`.

The model is libfyvterm. The driver keeps two models. The terminal model gets
every byte at once. The window model gets the bytes up to the end of the last
complete synchronized update (`CSI ? 2026 l`). A frame paints only the cells
that changed, so the window is whole only at a frame end. The steps that
look at the screen read the window model.

Besides the cells, the model keeps three lists:

- the rows that scrolled off the top;
- the rows that an erase of the whole display removed; and
- the text of each copy that the program made with OSC 52.

## The script

The script is a YAML mapping. Each key is optional, except `steps`.

| Key | Meaning |
|---|---|
| `rows`, `cols` | The size of the window. The default is 30 by 100. |
| `timeout` | The seconds that the session can last. The default is 15. |
| `wait_timeout` | The seconds that one wait step can last. The default is 5. |
| `ready` | The text that says the program is ready for keys. The default is the escape that shows the cursor. |
| `background` | The answer to the `OSC 11` query, such as `rgb:1e1e/1e1e/2e2e`. Without it, the query has no answer. |
| `background_while_starting` | When true, the driver stops the answer to `OSC 11` after it is ready. |
| `emoji_vs` | `narrow` plays a terminal that draws a base with U+FE0F in one column. |
| `snapshot` | A file for the capture at the end of the steps. A `snapshot` step takes the capture earlier. |
| `exit` | How the program must end: `status` (default 0), `signal` (a number or a name), and `clear` (send Ctrl-U before the exit line). |
| `steps` | The sequence of steps. |

Every deadline is multiplied by `$FYAI_TIMEOUT_SCALE`, or by
`$FYAI_TIMEOUT_SCALE_DEFAULT`. A sanitized build, or a suite that runs with
many jobs, takes more time for the same work. A pause is not a deadline and
is not scaled.

The driver reads the whole script before it starts the program. A key that it
does not know, a step of a wrong form, or a variable that is not set is an
error at this time.

A string can name a variable of the environment as `${NAME}`. `$$` is a dollar
sign. A string for `type` and `write` can hold any character of YAML,
including `\e` and `\x00`. Escape followed by a NUL byte makes the input parser
take the Escape as a lone key at once.

The driver does these things in order. It starts the program and waits for
`ready`. It does the steps. It writes the snapshot, when the script asks for
one. It sends the line `/exit` and waits for the program to end. If the
program does not end by the deadline, the driver sends SIGTERM, then SIGKILL.

## The steps

A step is a mapping. One key names the step and holds its value. The other
keys are modifiers.

A step that sends bytes, or that resizes the window, sets the mark. The mark
is the state of the capture and of the window at that time. The steps
`wait-frame`, `frame`, `wait-screen`, `wait-row`, `wait-repaint`, `wait-copy`,
and `wait-count` with `more` count from the mark.

### Steps that send

| Step | Action |
|---|---|
| `type: TEXT` | Send TEXT and a newline. |
| `write: TEXT` | Send TEXT as it is, for a key. |
| `click: TEXT` | Wait for TEXT on the screen. Press and release the mouse on its first cell. |
| `resize: COLS` or `resize: ROWSxCOLS` | Change the size of the window. The driver states the size again each second while it waits, so one lost SIGWINCH does not fail a case. |
| `touch: PATH` | Make an empty file. A held fixture waits for it. |
| `signal: N` | Send the signal to the program. N is a number or a name. |
| `snapshot: PATH` | Write the capture to PATH. |
| `mark: true` | Set the mark. |

### Steps that wait

All wait steps accept `timeout`: a number of seconds, or `session` for the
time that is left of the session.

| Step | The wait ends when |
|---|---|
| `wait: TEXT` | The capture holds TEXT. |
| `wait-frame: TEXT` | TEXT is in the capture after the mark and a frame end follows it. `from: start` looks from the first byte. |
| `wait-screen: TEXT` | TEXT is on the window, in a row that scrolled off after the mark, or in a row that an erase removed after the mark. |
| `wait-row: TEXT` | A row of the same places is TEXT alone, with the blanks at both ends removed. |
| `wait-gone: TEXT` | TEXT is not on the window. |
| `wait-repaint: TEXT` | The display was erased after the mark and TEXT is on the window. |
| `wait-copy: TEXT` | The program made a copy after the mark that holds TEXT. An empty TEXT takes any copy that is not empty. |
| `frame: N` | N frames ended after the mark. A key is read at the start of a frame, so two frames after it is when it has been acted on. |
| `wait-count: TEXT` | The capture holds TEXT `count: N` times, or `more: N` times more than at the mark. |
| `wait-file: PATH` | The file holds the text of `equals` (the whole file, without blanks at the ends) or of `contains`. |
| `wait-input: TEXT` | The row of the prompt holds TEXT. `marker` names the prompt mark. A row with nothing behind the mark does not count. |
| `resubmit: TEXT` | Send a newline until the capture holds `expect` one more time. `tries` (default 3) bounds the sends. Before a new send, the row of the prompt must hold TEXT again. |
| `sleep: SECONDS` | Wait for a time. Only the test of the driver uses it. |

Do not use `wait:` for text that the command row also holds. Use `wait-row`
or `wait-screen` for the output of the program.

## Rules for a case

- Wait for a state, not for a time. The driver has no pause after a key.
- Do not wait for a line of the capture when a frame paints only the cells that
  changed. Use `wait-screen`.
- Hold a mock reply with `wait_for:` and release it with `touch:`.
- Write an `FYAI_PTY_` variable in no case. `tests/case-lint.sh` fails on it.
