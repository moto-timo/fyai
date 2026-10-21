# Upstream notice

`web/` is a fork of the web UI of llama.cpp, `tools/ui`, from
<https://github.com/ggml-org/llama.cpp>, used under the MIT license:

```text
MIT License

Copyright (c) 2023-2025 The ggml authors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

Changes from upstream:

- `server/bridge.mjs` is new: it runs `fyai claude-sdk` and streams the
  Agent SDK protocol.
- `src/lib/services/fyai.service.ts` is new: the turn transport.
- `src/lib/stores/chat/index.svelte.ts` maps protocol frames to chat
  messages and no longer runs an agent loop.
- The llama-server API surface is replaced by `/api/fyai/chat`, `/props`,
  `/v1/models` and `/slots` of the bridge.
- Titles come from the first line of a message, not from a model request.
