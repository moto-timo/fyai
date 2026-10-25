<script lang="ts">
	import { Check, Circle, CircleDot, ListTodo, Loader2, X } from '@lucide/svelte';
	import { AgenticSectionType } from '$lib/enums';
	import { parseTodos } from '$lib/services/fyai.tools';
	import type { AgenticSection } from '$lib/types';

	interface Props {
		section: AgenticSection;
		isStreaming?: boolean;
	}

	let { isStreaming = false, section }: Props = $props();

	const isPending = $derived(section.type === AgenticSectionType.TOOL_CALL_PENDING);
	const isStreamingCall = $derived(section.type === AgenticSectionType.TOOL_CALL_STREAMING);
	const showSpinner = $derived(isPending || (isStreamingCall && isStreaming));
	const items = $derived(parseTodos(section.toolArgs));
	const done = $derived(items.filter((item) => item.status === 'completed').length);
</script>

<div class="py-1.5">
	<div class="text-muted-foreground flex items-center gap-2">
		<ListTodo class="text-muted-foreground/60 h-3.5 w-3.5 shrink-0" />

		<span class="text-foreground/80 text-sm font-medium">Task list</span>

		{#if items.length}
			<span class="text-muted-foreground text-xs">{done} of {items.length} done</span>
		{/if}

		{#if showSpinner}
			<Loader2 class="text-muted-foreground/70 h-3 w-3 animate-spin" />
		{/if}
	</div>

	{#if items.length}
		<ul class="mt-1.5 flex flex-col gap-1 pl-5">
			{#each items as item, index (index)}
				<li
					class="flex items-start gap-2 text-sm {item.status === 'completed' ||
					item.status === 'cancelled'
						? 'text-muted-foreground'
						: 'text-foreground/90'}"
				>
					{#if item.status === 'completed'}
						<Check class="mt-0.5 h-3.5 w-3.5 shrink-0 text-green-600 dark:text-green-400" />
					{:else if item.status === 'in_progress'}
						<CircleDot class="mt-0.5 h-3.5 w-3.5 shrink-0 text-blue-600 dark:text-blue-400" />
					{:else if item.status === 'cancelled'}
						<X class="mt-0.5 h-3.5 w-3.5 shrink-0 text-muted-foreground/70" />
					{:else}
						<Circle class="mt-0.5 h-3.5 w-3.5 shrink-0 text-muted-foreground/70" />
					{/if}

					<span class={item.status === 'cancelled' ? 'line-through' : ''}>{item.content}</span>
				</li>
			{/each}
		</ul>
	{/if}
</div>
