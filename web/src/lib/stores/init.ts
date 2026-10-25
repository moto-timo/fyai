// direct imports, not via the barrel, to avoid circular deps
import './fyai-backend.svelte';
import { backendStore } from './backend.svelte';
import { conversationsStore } from './conversations/index.svelte';
import { permissionsStore } from './permissions.svelte';
import { settingsStore } from './settings/index.svelte';
import { tabsStore } from './tabs.svelte';
import { toolsStore } from './tools.svelte';
import { versionStore } from './version.svelte';
import { browser } from '$app/environment';
import { forcedBackend } from '$lib/services/backend/forced';
import { DatabaseService } from '$lib/services/database.service';
import { MigrationService } from '$lib/services/migration.service';

let startup: Promise<void> | null = null;

export function initStores(): Promise<void> {
	if (!browser) return Promise.resolve();

	startup ??= (async () => {
		await backendStore.detect(
			forcedBackend({
				build: import.meta.env?.VITE_PUBLIC_BACKEND,
				search: window.location.search,
				storage: (key) => localStorage.getItem(key)
			})
		);

		/*
		 * A server that keeps the conversations leaves none in the browser: the
		 * tables are in memory, and the old database is neither read nor made.
		 */
		const serverConversations = backendStore.supports('serverConversations');

		if (serverConversations) await DatabaseService.useMemory();

		await MigrationService.runAllMigrations({ database: !serverConversations });

		settingsStore.initialize();
		permissionsStore.initialize();
		toolsStore.initialize();
		void versionStore.initialize();

		// the full conversation list loads in the background; once it is back,
		// prune persisted tabs against the conversations that still exist
		void conversationsStore.initialize().then(() => {
			tabsStore.init(conversationsStore.conversations.map((c) => c.id));
		});
	})();

	return startup;
}
