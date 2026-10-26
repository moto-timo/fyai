// SPDX-License-Identifier: MIT
/**
 * The project that the bridge serves, and the desktop app's way to open
 * another. Only the Electron app has the second: a browser tab belongs to the
 * bridge it came from.
 */

import { apiFetch } from '$lib/utils/api-fetch';

export interface FyaiProject {
	/** True when an arena exists for the directory, as fyai looks for it. */
	arena: boolean;
	dir: string;
	name: string;
}

/** The actions that the Electron preload exposes as `window.fyaiDesktop`. */
export interface FyaiDesktop {
	chooseProject(): Promise<void>;
	openProject(dir: string): Promise<boolean>;
	recentProjects(): Promise<string[]>;
}

export async function fetchFyaiProject(): Promise<FyaiProject | null> {
	const info = await apiFetch<{ project?: FyaiProject }>('/api/fyai/info');

	return info.project ?? null;
}

export function fyaiDesktop(): FyaiDesktop | null {
	if (typeof window === 'undefined') return null;

	return (window as unknown as { fyaiDesktop?: FyaiDesktop }).fyaiDesktop ?? null;
}
