// SPDX-License-Identifier: MIT
/**
 * The backend kind that the user or the build forces, or null to detect it. A
 * page is built once for every server, so the kind can come from three places,
 * in this order: the `backend` query parameter of the address, the
 * `fyai-backend` entry of the local storage, and the build setting
 * `VITE_PUBLIC_BACKEND`. A page that is served from a host that has no bridge
 * is forced this way, because it has nothing to probe.
 */

export const FORCED_BACKEND_PARAM = 'backend';
export const FORCED_BACKEND_STORAGE_KEY = 'fyai-backend';

interface Sources {
	/** The query string of the address, with or without its `?`. */
	search?: string;
	/** The reader of the local storage, which can fail or be missing. */
	storage?: (key: string) => string | null;
	/** The build setting. */
	build?: string;
}

export function forcedBackend(sources: Sources): string | null {
	const fromQuery = new URLSearchParams(sources.search ?? '').get(FORCED_BACKEND_PARAM);

	if (fromQuery) return fromQuery;

	try {
		const stored = sources.storage?.(FORCED_BACKEND_STORAGE_KEY);

		if (stored) return stored;
	} catch {
		// storage that cannot be read is not a choice
	}

	return sources.build || null;
}
