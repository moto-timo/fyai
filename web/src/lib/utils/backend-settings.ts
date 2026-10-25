// SPDX-License-Identifier: MIT
import { SETTINGS_SECTION_REQUIRES } from '$lib/constants/backend-capabilities.constants';
import type { Backend } from '$lib/services/backend/types';
import type { SettingsSection } from '$lib/types';

/**
 * The sections of the settings dialog that the backend shows, with the fields
 * that it shows. A section whose capability the backend lacks goes, and so
 * does a section whose fields are all hidden. A section that has no fields of
 * its own, such as a tab, stays.
 */
export function visibleSettingsSections(
	sections: SettingsSection[],
	backend: Pick<Backend, 'capabilities' | 'kind'>
): SettingsSection[] {
	const result: SettingsSection[] = [];

	for (const section of sections) {
		const needs = SETTINGS_SECTION_REQUIRES[section.slug];

		if (needs && !backend.capabilities[needs]) continue;

		const all = section.fields ?? [];
		const fields = all.filter((f) => !f.backends || f.backends.includes(backend.kind));

		if (all.length > 0 && fields.length === 0) continue;

		result.push(fields.length === all.length ? section : { ...section, fields });
	}

	return result;
}
