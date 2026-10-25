// SPDX-License-Identifier: MIT
import type { Backend } from './types';

/** llama-server: every part of the page applies, and a turn is a chat completion. */
export const llamaBackend: Backend = {
	capabilities: {
		agenticLoop: true,
		browserMcp: true,
		browserTools: true,
		modelManager: true,
		sampling: true
	},
	kind: 'llama'
};
