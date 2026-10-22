import { apiFetch } from '$lib/utils/api-fetch';

/** One command that the bridge reports from `fyai schema`. */
export interface FyaiCommand {
	name: string;
	aliases: string[];
	title: string;
	description: string;
}

/**
 * The slash commands of the fyai behind the page. The bridge reads them from
 * `fyai schema commands`, so the picker offers what that fyai supports and
 * the page keeps no list of its own.
 */
class FyaiCommandsStore {
	commands = $state<FyaiCommand[]>([]);
	private loading: Promise<void> | null = null;

	/** Fetch the list once; a bridge without it leaves the list empty. */
	load(): Promise<void> {
		this.loading ??= apiFetch<{ commands?: FyaiCommand[] }>('/api/fyai/commands')
			.then((res) => {
				this.commands = Array.isArray(res.commands) ? res.commands : [];
			})
			.catch(() => {
				this.commands = [];
			});

		return this.loading;
	}
}

export const fyaiCommandsStore = new FyaiCommandsStore();
