// SPDX-License-Identifier: MIT
import type { SettingsSection } from '$lib/types';

/**
 * The sections of the settings dialog with the fields that the backend shows.
 * A section whose fields are all hidden goes too; a section that has no
 * fields of its own, such as a tab, stays.
 */
export function visibleSettingsSections(
	sections: SettingsSection[],
	backendKind: string
): SettingsSection[] {
	const result: SettingsSection[] = [];

	for (const section of sections) {
		const all = section.fields ?? [];
		const fields = all.filter((f) => !f.backends || f.backends.includes(backendKind));

		if (all.length > 0 && fields.length === 0) continue;

		result.push(fields.length === all.length ? section : { ...section, fields });
	}

	return result;
}
