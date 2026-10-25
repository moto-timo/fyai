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

Upstream base: llama.cpp commit 1801b7cd, imported unchanged in fyai commit
d7ac555e. `doc/fyai-web.md` describes how to merge a newer upstream.

New files, none of which exists upstream:

- `server/` (the bridge `bridge.mjs`, `protocol.mjs`, and the end-to-end
  scripts), `electron/` (the desktop app), and the fyai scripts and launchers
  in `scripts/`.
- `src/lib/services/backend/` (the backend seam and the llama-server
  backend), `src/lib/stores/backend.svelte.ts`,
  `src/lib/stores/fyai-backend.svelte.ts`, `src/lib/services/fyai.service.ts`,
  `src/lib/services/fyai.turn.ts`, `src/lib/services/fyai.tools.ts`, `src/lib/services/fyai.conversations.ts`, `src/lib/services/backend/forced.ts`, `ChatMessageToolCallBlockTodo.svelte`, `src/lib/utils/backend-settings.ts` and
  `src/lib/constants/backend-capabilities.constants.ts`.
- `README.fyai.md`, the manual of the fyai build. `README.md` is upstream's.

Hook points, the upstream files that fyai changed. Each change is small and
calls into a new file; merge them first when upstream moves:

| File | Hook |
| ---- | ---- |
| `src/lib/stores/chat/index.svelte.ts` | `backendStore.active.runTurn` before the agentic loop; `handleLine` at the start of `sendMessage`; `titleFor` in `generateTitleWithLLM`; the agentic loop and the plain path only with the `agenticLoop` capability |
| `src/lib/stores/init.ts` | registers the fyai backend and detects the backend at start, or takes the forced kind; with `serverConversations` the tables go to memory and the database migration is skipped |
| `src/lib/stores/index.ts` | exports `backendStore` |
| `src/lib/stores/conversations/index.svelte.ts` | the backend lists the conversations before the list loads, names a new one (`newConversationId`), reads one when it opens (`hydrateConversation`), and hears of a delete and a rename |
| `src/lib/services/database.service.ts` | `useMemory()` swaps IndexedDB for memory (`fake-indexeddb`); `replaceConversation`; `createConversation` takes an ID |
| `src/lib/services/migration.service.ts` | the IndexedDB migration is skipped when the page keeps no database |
| `src/lib/services/router.service.ts` | the ID in the address is URL-encoded, because a branch name holds slashes |
| `src/lib/components/app/chat/ChatMessages/ChatMessageActions/ChatMessageActionIcons/ChatMessageActionIcons.svelte` | the fork action needs a page that keeps the conversations |
| `src/lib/components/app/chat/ChatMessages/ChatMessage/ChatMessageToolCall/ChatMessageToolCallBlock.svelte` | the task list tool has its block |
| `src/lib/stores/ui.svelte.ts` | `openModelsManager` needs `modelManager` |
| `src/lib/stores/models/index.svelte.ts` | `findModelByName` ignores provider prefix and punctuation |
| `src/lib/components/app/chat/ChatForm/ChatForm.svelte` | `selectModel` for `/model NAME` |
| `src/lib/components/app/chat/ChatForm/ChatFormActions/ChatFormActionAdd/ChatFormActionAddDropdown.svelte` | Tools submenu needs `browserTools` |
| `src/lib/components/app/navigation/SidebarNavigation/SidebarNavigationActions.svelte`, `src/lib/components/app/models/ModelsSelector/ModelsSelectorDropdown.svelte` | the entries of the models manager and the MCP client need `modelManager` and `browserMcp` |
| `src/lib/components/app/settings/SettingsChat/SettingsChat.svelte` | sections come from `visibleSettingsSections` |
| `src/lib/hooks/use-chat-form-pickers.svelte.ts` | commands of the backend in the `/` picker |
| `src/lib/utils/chat-commands.ts`, `src/lib/types/chat.d.ts`, `src/lib/enums/chat.enums.ts`, `src/lib/constants/icons.constants.ts` | the `backend` command action |
| `src/lib/constants/settings.constants.ts`, `settings-keys.constants.ts`, `src/lib/types/settings.d.ts` | the Provider API keys field and the `backends` property of a field |
| `src/lib/utils/index.ts` | exports `visibleSettingsSections` |
| `src/routes/(chat)/chat/[id]/+page.svelte` | selects the first model of an empty conversation |
| `src/lib/constants/app.constants.ts`, `pwa.constants.ts`, `src/routes/search/+page.svelte` | the name `fyai` |
| `package.json`, `package-lock.json`, `vite.config.ts`, `.env.example`, `.gitignore`, `scripts/dev.sh` | scripts, Electron, the proxy to the bridge |
| `CMakeLists.txt`, `sources.cmake`, `ui.cpp.in`, `ui.h.in` | removed: the llama-server embedding |
| `tests/client/chat-form-slash-commands.svelte.test.ts`, `tests/client/components/ChatFormPickersHarness.svelte` | the `selectModel` option of the picker hook |
