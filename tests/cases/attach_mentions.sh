#!/bin/bash
# SPDX-License-Identifier: MIT
# @PATH in a line attaches the file it names, as `attach` does: an image as an
# image part, a text file as its text after the words. Blanks are quoted or
# escaped, ~/ is the home directory, "\@" and "@@" are a literal "@", and a
# bare @WORD that names no file stays text. A line that fails to attach is not
# sent, and the task of a sub-agent takes no mention.
set -eu
. "$(dirname "$0")/../harness.sh"

fyai_test_setup

printf 'line one\nline ``` two\n' > notes.txt
printf '\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR\x00\x00\x04\x00\x00\x00\x03\x00\x08\x06\x00\x00\x00' \
    > "my shot.png"
printf 'home text\n' > "$HOME/home.txt"
printf '\x00\x01\x02\x03binary' > blob.bin

catalog() {
	cat > catalog.yaml <<CAT
models:
- name: img-model
  modalities: [text, image]
  capabilities: []
providers:
- name: prov
  root_url: $MOCK_URL
  endpoints:
  - protocol: responses
    endpoint: /v1/responses
  models:
  - canonical_id: img-model
    provider_model_id: img-model
CAT
	run_fyai catalog import catalog.yaml
	assert_status 0
}

ask() {
	run_fyai --new --set display/stream=false --set tools=false \
		 -m prov/img-model "$1"
}

# A text file, an image whose name has a blank, and a file under ~/.
mock_start responses_basic.json
catalog
ask 'look at @notes.txt and @"my shot.png" and @~/home.txt'
assert_status 0
assert_request 0 'any(p.get("type") == "input_text" and p["text"].startswith("look at notes.txt and my shot.png and ~/home.txt") for p in r["body"]["input"][-1]["content"])'
assert_request 0 'any(p.get("type") == "input_text" and "File: notes.txt\n````\nline one\nline ``` two\n````" in p["text"] for p in r["body"]["input"][-1]["content"])'
assert_request 0 'any(p.get("type") == "input_text" and "File: ~/home.txt\n```\nhome text\n```" in p["text"] for p in r["body"]["input"][-1]["content"])'
assert_request 0 'any(p.get("type") == "input_image" for p in r["body"]["input"][-1]["content"])'
mock_stop 1

# An escaped blank does as a quote; text alone is one string.
mock_start responses_basic.json
catalog
ask 'ping @nobody, mail a@b.com, \@x and @@y, @my\ shot.png'
assert_status 0
assert_request 0 'any(p.get("type") == "input_text" and p["text"] == "ping @nobody, mail a@b.com, @x and @y, my shot.png" for p in r["body"]["input"][-1]["content"])'
mock_stop 1

# A text file alone makes no content sequence on the wire: one string.
mock_start responses_basic.json
catalog
ask 'read @notes.txt'
assert_status 0
assert_request 0 'isinstance(r["body"]["input"][-1]["content"], str) and r["body"]["input"][-1]["content"].startswith("read notes.txt\n\nFile: notes.txt")'
mock_stop 1

# The single quote does as the double quote.
mock_start responses_basic.json
catalog
ask "look at @'my shot.png'"
assert_status 0
assert_request 0 'any(p.get("type") == "input_text" and p["text"] == "look at my shot.png" for p in r["body"]["input"][-1]["content"])'
assert_request 0 'any(p.get("type") == "input_image" for p in r["body"]["input"][-1]["content"])'
mock_stop 1

# An empty file is a file part with no lines.
: > empty.txt
mock_start responses_basic.json
catalog
ask 'see @empty.txt'
assert_status 0
assert_request 0 'isinstance(r["body"]["input"][-1]["content"], str) and r["body"]["input"][-1]["content"] == "see empty.txt\n\nFile: empty.txt\n```\n```"'
mock_stop 1

# Two mentions of the same file attach it twice, and each one counts against
# media/max_per_message.
mock_start responses_basic.json
catalog
ask 'diff @notes.txt with @notes.txt'
assert_status 0
assert_request 0 'r["body"]["input"][-1]["content"].count("File: notes.txt") == 2'
mock_stop 1

# A mention that is no mention is text: a lone @ at the end, a quote that
# does not close, and a bare word that names nothing.
mock_start responses_basic.json
catalog
ask 'what does @" mean, and an @'
assert_status 0
assert_request 0 'r["body"]["input"][-1]["content"] == "what does @\" mean, and an @"'
mock_stop 1

# A line that cannot attach is refused and nothing is sent: a quoted path
# that names no file, an empty quoted path, a file that is neither an image
# nor text, a text file over the limit, one over media/max_bytes, and a
# second attachment over media/max_per_message.
head -c 300000 /dev/zero | tr '\0' 'a' > big.txt
head -c 200 /dev/zero | tr '\0' 'b' > mid.txt
mock_start responses_basic.json
catalog
ask 'look at @"no such.txt"'
assert_status_nonzero
assert_stderr_contains "could not open 'no such.txt'"
ask 'look at @""'
assert_status_nonzero
assert_stderr_contains "names no path"
ask 'look at @blob.bin'
assert_status_nonzero
assert_stderr_contains "neither an image nor a text file"
printf 'plain \033[31mred\n' > ansi.txt
ask 'look at @ansi.txt'
assert_status_nonzero
assert_stderr_contains "neither an image nor a text file"
ask 'look at @big.txt'
assert_status_nonzero
assert_stderr_contains "more than the 262144 bytes of text"
run_fyai --new --set display/stream=false --set tools=false \
	 --set media/max_bytes=100 -m prov/img-model 'look at @mid.txt'
assert_status_nonzero
assert_stderr_contains "more than the 100 bytes of text"
run_fyai --new --set display/stream=false --set tools=false \
	 --set media/max_per_message=1 -m prov/img-model \
	 'look at @notes.txt and @"my shot.png"'
assert_status_nonzero
assert_stderr_contains "at most 1 attachments"
mock_stop 0

# The task of a sub-agent is not a line of the user: its mentions stay text,
# and no file leaves with the instruction.
mock_start agent_verb.json
run_fyai --set api=chat-completions --set display/stream=false \
	 --set "api_url=$MOCK_URL/v1/chat/completions" -m mock-model \
	 agent "read @notes.txt and report back"
assert_status 0
assert_request 0 'any(m.get("role") == "user" and "read @notes.txt and report back" in m.get("content", "") for m in r["body"]["messages"])'
assert_no_request 'any("File: notes.txt" in str(m.get("content", "")) for m in r["body"]["messages"])'
mock_stop 2
assert_state_absent "File: notes.txt" dump state

# The command says what it attached.
run_fyai attach notes.txt --output json
assert_status 0
assert_stdout_contains '"file": "notes.txt"'
assert_stdout_contains '"lines": 2'

pass
