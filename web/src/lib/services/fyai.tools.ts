// SPDX-License-Identifier: MIT
/**
 * How the tools of fyai look in the page. The page has a card for the tools
 * of llama-server (`exec_shell_command`, `read_file`, `write_file`,
 * `edit_file`), keyed by their names and the shape of their arguments. fyai
 * names its tools as the Claude Agent SDK does (`Bash`, `Read`, `Write`,
 * `Edit`), so a call is shown under the name and arguments of the card that
 * fits it. Any other tool keeps its own name and the default card.
 */

import { BuiltInTool } from '$lib/enums';

export interface ToolView {
	arguments: string;
	name: string;
}

type Fields = Record<string, unknown>;

/** The fields of @input without the keys in @drop. */
function without(input: Fields, drop: string[]): Fields {
	return Object.fromEntries(Object.entries(input).filter(([key]) => !drop.includes(key)));
}

/** The name and arguments that the page shows for a call of the tool @name. */
export function fyaiToolView(name: string, input: unknown): ToolView {
	const fields: Fields = input && typeof input === 'object' ? (input as Fields) : {};
	const path = fields.file_path ?? fields.path;

	switch (name) {
		case 'Bash':
			return {
				arguments: JSON.stringify(fields),
				name: BuiltInTool.SERVER_EXEC_SHELL_COMMAND
			};

		case 'Read':
			return {
				arguments: JSON.stringify({ ...without(fields, ['file_path']), path }),
				name: BuiltInTool.SERVER_READ_FILE
			};

		case 'Write':
			return {
				arguments: JSON.stringify({ ...without(fields, ['file_path']), path }),
				name: BuiltInTool.SERVER_WRITE_FILE
			};

		case 'Edit':
			return {
				arguments: JSON.stringify({
					edits: [{ new_text: fields.new_string ?? '', old_text: fields.old_string ?? '' }],
					path
				}),
				name: BuiltInTool.SERVER_EDIT_FILE
			};

		default:
			return { arguments: JSON.stringify(fields), name };
	}
}

/**
 * The text of a tool result as the cards read it. A card shows a failure when
 * the result is an object with an `error` text, so a result that fyai marked
 * as an error becomes one. A result that succeeded stays as it is.
 */
export function toolResultForCard(text: string, isError: boolean): string {
	return isError ? JSON.stringify({ error: text || 'the tool failed' }) : text;
}

/**
 * The name and arguments that the page shows for a call as fyai stores it. The
 * stored names are those of fyai: `shell` and `exec_command` are the shell
 * card, and `read_file` and `write_file` already have the arguments of their
 * cards. A live turn shows the names of the SDK instead (`fyaiToolView`).
 *
 * @param name the stored name of the tool
 * @param args the stored arguments, a JSON text
 */
export function fyaiStoredToolView(name: string, args: string): ToolView {
	let input: unknown = {};

	try {
		input = JSON.parse(args);
	} catch {
		/* Arguments that are not JSON show as none. */
	}

	if (name === 'shell' || name === 'exec_command') return fyaiToolView('Bash', input);

	return fyaiToolView(name, input);
}
