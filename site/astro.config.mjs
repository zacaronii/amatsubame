// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

export default defineConfig({
	site: 'https://amatsubame.com',
	integrations: [
		starlight({
			title: 'Amatsubame',
			description: 'Japanese immersion apps for your own Kavita, Jellyfin and Audiobookshelf servers.',
			logo: { light: './src/assets/swift.svg', dark: './src/assets/swift-dark.svg', alt: '' },
			favicon: '/favicon.svg',
			head: [
				// The link preview: the swift and the four apps (site/scripts/social-image.mjs).
				{ tag: 'meta', attrs: { property: 'og:image', content: 'https://amatsubame.com/social.png' } },
				{ tag: 'meta', attrs: { property: 'og:image:width', content: '1200' } },
				{ tag: 'meta', attrs: { property: 'og:image:height', content: '630' } },
				{ tag: 'meta', attrs: { property: 'og:image:alt', content: 'The Amatsubame swift with the Yomu, Miru, Kiku and Hiku app icons' } },
				{ tag: 'meta', attrs: { name: 'twitter:card', content: 'summary_large_image' } },
				{ tag: 'meta', attrs: { name: 'twitter:image', content: 'https://amatsubame.com/social.png' } },
			],
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
