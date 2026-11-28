// Draws the 1200×630 link preview (public/social.png): the brand swift dreaming 「もう一話だけ…」, the
// name, and the four app icons. docs/media/banner.png (the README's banner) is the same picture cut to
// its art, with an even margin all round.
// Run from site/: `node scripts/social-image.mjs`. Uses the icons in ../Design.
import sharp from 'sharp';
import { readFile } from 'node:fs/promises';

const width = 1200;
const height = 630;
const design = new URL('../../Design/', import.meta.url);

const sky = `
	<defs>
		<linearGradient id="sky" x1="0" y1="0" x2="1" y2="1">
			<stop offset="0" stop-color="#eef0ff"/>
			<stop offset="1" stop-color="#c9cff9"/>
		</linearGradient>
	</defs>
	<rect width="${width}" height="${height}" fill="url(#sky)"/>`;
const words = `
	<text x="600" y="250" font-family="Hiragino Sans, Helvetica Neue, sans-serif" font-size="80" font-weight="700" fill="#1f2547">Amatsubame</text>
	<text x="602" y="312" font-family="Hiragino Sans, Helvetica Neue, sans-serif" font-size="38" fill="#3d4596">Japanese immersion apps</text>
	<text x="602" y="360" font-family="Hiragino Sans, Helvetica Neue, sans-serif" font-size="30" fill="#5b63a8">for your own media servers</text>`;
const svg = (content) => Buffer.from(`<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}">${content}</svg>`);

/** An app icon as a rounded square (the iOS corner), `size` px wide. */
async function icon(name, size) {
	const radius = Math.round(size * 0.225);
	const mask = Buffer.from(`<svg width="${size}" height="${size}"><rect width="${size}" height="${size}" rx="${radius}" ry="${radius}"/></svg>`);
	return sharp(await readFile(new URL(`icons/${name}/${name}-icon-1024.png`, design)))
		.resize(size, size)
		.composite([{ input: mask, blend: 'dest-in' }])
		.png()
		.toBuffer();
}

// The brand swift is wide (its thought cloud): fit it into the left half.
const swift = await sharp(await readFile(new URL('mascot/swift.svg', design)), { density: 300 })
	.resize(560, 420, { fit: 'inside' })
	.png()
	.toBuffer();
const swiftHeight = (await sharp(swift).metadata()).height;

const iconSize = 112;
const gap = 28;
const icons = await Promise.all(['Yomu', 'Miru', 'Kiku', 'Hiku'].map((name) => icon(name, iconSize)));

const layers = [
	{ input: swift, left: 20, top: Math.round((height - swiftHeight) / 2) - 20 },
	...icons.map((input, index) => ({ input, left: 602 + index * (iconSize + gap), top: 420 })),
];
const social = await sharp(svg(sky + words)).composite(layers).png().toBuffer();
await sharp(social).toFile(new URL('../public/social.png', import.meta.url).pathname);
console.log('Wrote public/social.png');

// The banner: the art's box (the same layers on a transparent canvas, trimmed), plus a margin.
const transparent = await sharp(svg(words)).composite(layers).png().toBuffer();
const { info } = await sharp(transparent).trim({ threshold: 1 }).toBuffer({ resolveWithObject: true });
const margin = 28;
const box = { left: -info.trimOffsetLeft, top: -info.trimOffsetTop, width: info.width, height: info.height };
const banner = {
	left: Math.max(0, box.left - margin),
	top: Math.max(0, box.top - margin),
	width: Math.min(width, box.width + 2 * margin),
	height: Math.min(height, box.height + 2 * margin),
};
await sharp(social).extract(banner).toFile(new URL('../../docs/media/banner.png', import.meta.url).pathname);
console.log(`Wrote docs/media/banner.png (${banner.width}×${banner.height})`);
