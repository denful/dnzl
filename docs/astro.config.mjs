// @ts-check
import { defineConfig, fontProviders } from 'astro/config';
import starlight from '@astrojs/starlight';

import mermaid from 'astro-mermaid';
import catppuccin from "@catppuccin/starlight";

// https://astro.build/config
export default defineConfig({
	site: 'https://dnzl.denful.dev',
	experimental: {
		fonts: [
			{
				provider: fontProviders.google(),
				name: "Victor Mono",
				cssVariable: "--font-victor-mono",
			},
			{
				provider: fontProviders.google(),
				name: "JetBrains Mono",
				cssVariable: "--font-jetbrains-mono",
			},
		],
	},
	integrations: [
		mermaid({
			theme: 'forest',
			autoTheme: true
		}),
		starlight({
			title: 'dnzl',
			social: [
        { icon: 'github', label: 'GitHub', href: 'https://github.com/denful/dnzl' }
      ],
			sidebar: [
				{
					label: 'dnzl',
					items: [
						{ label: 'Overview', slug: 'overview' },
					],
				},
				{
					label: 'Understand',
					items: [
						{ label: 'Actors and Streams', slug: 'explanation/actors-and-streams' },
						{ label: 'Reply and Become', slug: 'explanation/reply-become' },
						{ label: 'Composition', slug: 'explanation/composition' },
						{ label: 'Lazy Evaluation', slug: 'explanation/lazy-evaluation' },
					],
				},
				{
					label: 'Guides',
					items: [
						{ label: 'Getting Started', slug: 'guides/getting-started' },
						{ label: 'Building Pipelines', slug: 'guides/pipeline' },
						{ label: 'Private Channels', slug: 'guides/private-channels' },
						{ label: 'World Edge', slug: 'guides/world-edge' },
					],
				},
				{
					label: 'Patterns',
					items: [
						{ label: 'Proxy and Delegation', slug: 'patterns/proxy' },
						{ label: 'Multi-Output Cycles', slug: 'patterns/multi-output' },
						{ label: 'Scatter-Gather', slug: 'patterns/scatter-gather' },
						{ label: 'Ping-Pong', slug: 'patterns/ping-pong' },
						{ label: 'Dynamic Dispatch', slug: 'patterns/dynamic-dispatch' },
						{ label: 'Capability Refs', slug: 'patterns/capability-refs' },
					],
				},
				{
					label: 'Reference',
					items: [
						{ label: 'actor', slug: 'reference/actor' },
						{ label: 'reply', slug: 'reference/reply' },
						{ label: 'become', slug: 'reference/become' },
						{ label: 'send', slug: 'reference/send' },
						{ label: 'merge', slug: 'reference/merge' },
						{ label: 'ST Combinators', slug: 'reference/st-combinators' },
						{ label: 'ned Primitives', slug: 'reference/ned-primitives' },
					],
				},
			],
			components: {
				Head: './src/components/Head.astro',
				Sidebar: './src/components/Sidebar.astro',
				Footer: './src/components/Footer.astro',
				SocialIcons: './src/components/SocialIcons.astro',
				PageSidebar: './src/components/PageSidebar.astro',
				Hero: './src/components/Hero.astro',
			},
			plugins: [
				catppuccin({
					dark: { flavor: "macchiato", accent: "mauve" },
					light: { flavor: "latte", accent: "mauve" },
				}),
			],
			editLink: {
				baseUrl: 'https://github.com/denful/dnzl/edit/main/docs/',
			},
			customCss: [
				'./src/styles/custom.css'
			],
		}),
	],
});
