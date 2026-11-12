// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

export default defineConfig({
	site: 'https://amatsubame.com',
	integrations: [
		starlight({
			title: 'Amatsubame',
			description: 'Japanese immersion apps for your own Kavita, Jellyfin and Audiobookshelf servers.',
			logo: { src: './src/assets/yomu.png', alt: '' },
			favicon: '/favicon.png',
			social: [{ icon: 'github', label: 'GitHub', href: 'https://github.com/zacaronii/amatsubame' }],
			editLink: { baseUrl: 'https://github.com/zacaronii/amatsubame/edit/main/site/' },
			customCss: ['./src/styles/custom.css'],
			sidebar: [
				{ label: 'Start here', items: ['getting-started'] },
				{ label: 'Apps', items: ['yomu', 'miru', 'kiku', 'hiku'] },
				{ label: 'Shared', items: ['lookup-and-anki', 'kaku'] },
				{ label: 'About', items: ['privacy', 'support'] },
			],
		}),
	],
});
