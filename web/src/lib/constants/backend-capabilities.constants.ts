// SPDX-License-Identifier: MIT
import { SETTINGS_SECTION_SLUGS } from './settings.constants';
import type { BackendCapabilities } from '$lib/services/backend/types';

/**
 * The capability that a backend needs for the settings dialog to show a
 * section. A section that is not listed shows for every backend.
 */
export const SETTINGS_SECTION_REQUIRES: Record<string, keyof BackendCapabilities> = {
	[SETTINGS_SECTION_SLUGS.AGENTIC]: 'agenticLoop',
	[SETTINGS_SECTION_SLUGS.SAMPLING_PENALTIES]: 'sampling',
	[SETTINGS_SECTION_SLUGS.TOOLS]: 'browserTools'
};
