<script lang="ts">
	import { ChevronDown, FolderOpen } from '@lucide/svelte';
	import { fetchFyaiProject, fyaiDesktop, type FyaiProject } from '$lib/services/fyai.project';
	import { onMount } from 'svelte';

	interface Props {
		class?: string;
	}

	let { class: className = '' }: Props = $props();

	const desktop = fyaiDesktop();

	let project = $state<FyaiProject | null>(null);
	let recent = $state<string[]>([]);
	let menuOpen = $state(false);
	let failure = $state<string | null>(null);

	onMount(() => {
		fetchFyaiProject()
			.then((value) => (project = value))
			.catch((error: Error) => (failure = error.message));
	});

	async function toggleMenu() {
		menuOpen = !menuOpen;

		if (menuOpen && desktop) recent = await desktop.recentProjects();
	}

	async function open(action: () => Promise<unknown>) {
		menuOpen = false;

		try {
			await action();
		} catch (error) {
			failure = (error as Error).message;
		}
	}
</script>

{#if project}
	<div class="relative {className}">
		<button
			class="flex w-full items-center gap-2 rounded-md px-2 py-1.5 text-left text-sm hover:bg-accent disabled:cursor-default disabled:hover:bg-transparent"
			disabled={!desktop}
			onclick={toggleMenu}
			title={project.arena ? project.dir : `${project.dir}: no arena, run fyai init there`}
		>
			<FolderOpen class="h-4 w-4 shrink-0" />

			<span class="min-w-0 flex-1 truncate">{project.name}</span>

			{#if !project.arena}<span class="text-xs text-destructive">no arena</span>{/if}

			{#if desktop}<ChevronDown class="h-4 w-4 shrink-0" />{/if}
		</button>

		{#if menuOpen && desktop}
			<div
				class="absolute inset-x-0 top-full z-50 mt-1 rounded-md border bg-popover p-1 text-popover-foreground shadow-md"
			>
				<button
					class="w-full rounded px-2 py-1.5 text-left text-sm hover:bg-accent"
					onclick={() => open(() => desktop.chooseProject())}
				>
					Open project...
				</button>

				{#each recent.filter((dir) => dir !== project?.dir) as dir (dir)}
					<button
						class="w-full truncate rounded px-2 py-1.5 text-left text-xs text-muted-foreground hover:bg-accent"
						onclick={() => open(() => desktop.openProject(dir))}
						title={dir}
					>
						{dir}
					</button>
				{/each}
			</div>
		{/if}

		{#if failure}<p class="px-2 text-xs text-destructive">{failure}</p>{/if}
	</div>
{/if}
