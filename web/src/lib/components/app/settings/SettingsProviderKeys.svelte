<script lang="ts">
	import { Button } from '$lib/components/ui/button';
	import { Input } from '$lib/components/ui/input';
	import { fyaiKeys, type ProviderKeyStatus } from '$lib/services/fyai.keys';
	import { onMount } from 'svelte';

	let keys = $state<ProviderKeyStatus[]>([]);
	let drafts = $state<Record<string, string>>({});
	let error = $state('');

	async function refresh() {
		try {
			keys = await fyaiKeys.list();
			error = '';
		} catch (e) {
			error = e instanceof Error ? e.message : String(e);
		}
	}

	async function save(provider: string) {
		try {
			await fyaiKeys.set(provider, drafts[provider] ?? '');
			drafts[provider] = '';
			await refresh();
		} catch (e) {
			error = e instanceof Error ? e.message : String(e);
		}
	}

	async function remove(provider: string) {
		try {
			await fyaiKeys.remove(provider);
			await refresh();
		} catch (e) {
			error = e instanceof Error ? e.message : String(e);
		}
	}

	onMount(refresh);
</script>

<div class="space-y-3">
	<div>
		<h4 class="text-sm font-medium">Provider keys</h4>

		<p class="text-xs text-muted-foreground">
			fyai keeps a key in its own secret store. The page sends it once and never reads it back. A
			key in the environment of the bridge is used before the stored one.
		</p>
	</div>

	{#if error}
		<p class="text-xs text-destructive">{error}</p>
	{/if}

	{#each keys as entry (entry.provider)}
		<div class="flex items-center gap-2">
			<span class="w-28 shrink-0 text-sm">{entry.provider}</span>

			<span class="w-24 shrink-0 text-xs text-muted-foreground">
				{entry.stored ? 'stored' : entry.env ? 'environment' : 'not set'}
			</span>

			<Input
				bind:value={drafts[entry.provider]}
				autocomplete="off"
				class="h-8"
				placeholder={entry.stored ? 'replace the key' : 'enter a key'}
				type="password"
			/>

			<Button
				disabled={!drafts[entry.provider]?.trim()}
				onclick={() => save(entry.provider)}
				size="sm"
				variant="outline">Save</Button
			>

			{#if entry.stored}
				<Button onclick={() => remove(entry.provider)} size="sm" variant="ghost">Remove</Button>
			{/if}
		</div>
	{/each}
</div>
