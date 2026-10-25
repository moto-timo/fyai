// SPDX-License-Identifier: MIT
import type { SettingsSection } from '$lib/types';
import { visibleSettingsSections } from '$lib/utils/backend-settings';
import { describe, expect, it } from 'vitest';

const field = (key: string, backends?: string[]) =>
	({ backends, key, label: key, type: 'input' }) as never;
const section = (slug: string, fields?: unknown[]) =>
	({ fields, icon: {}, slug, title: slug }) as unknown as SettingsSection;

describe('visibleSettingsSections', () => {
	it('keeps a field that names no backend', () => {
		const out = visibleSettingsSections([section('a', [field('x')])], 'llama');

		expect(out[0].fields).toHaveLength(1);
	});

	it('shows a field only to the backends it names', () => {
		const sections = [section('a', [field('x'), field('y', ['fyai-bridge'])])];

		expect(visibleSettingsSections(sections, 'llama')[0].fields).toHaveLength(1);
		expect(visibleSettingsSections(sections, 'fyai-bridge')[0].fields).toHaveLength(2);
	});

	it('drops a section whose fields are all hidden', () => {
		const sections = [section('a', [field('y', ['fyai-bridge'])])];

		expect(visibleSettingsSections(sections, 'llama')).toHaveLength(0);
	});

	it('keeps a section that has no fields of its own', () => {
		expect(visibleSettingsSections([section('tools', [])], 'llama')).toHaveLength(1);
	});

	it('returns the same section object when nothing is hidden', () => {
		const one = section('a', [field('x')]);

		expect(visibleSettingsSections([one], 'llama')[0]).toBe(one);
	});
});
