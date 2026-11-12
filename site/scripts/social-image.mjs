// Draws the 1200×630 link preview (public/social.png): the swift, the name, and the four app icons.
// Run from site/: `node scripts/social-image.mjs`. Uses the icons in ../Design.
import sharp from 'sharp';
import { readFile } from 'node:fs/promises';

const width = 1200;
const height = 630;
const design = new URL('../../Design/', import.meta.url);

const background = Buffer.from(`
<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}">
	<defs>
		<linearGradient id="sky" x1="0" y1="0" x2="1" y2="1">
			<stop offset="0" stop-color="#eef0ff"/>
			<stop offset="1" stop-color="#c9cff9"/>
		</linearGradient>
	</defs>
	<rect width="${width}" height="${height}" fill="url(#sky)"/>
	<text x="560" y="250" font-family="Hiragino Sans, Helvetica Neue, sans-serif" font-size="80" font-weight="700" fill="#1f2547">Amatsubame</text>
	<text x="562" y="312" font-family="Hiragino Sans, Helvetica Neue, sans-serif" font-size="38" fill="#3d4596">Japanese immersion apps</text>
	<text x="562" y="360" font-family="Hiragino Sans, Helvetica Neue, sans-serif" font-size="30" fill="#5b63a8">for your own media servers</text>
</svg>`);

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

const swift = await sharp(await readFile(new URL('mascot/swift.svg', design)), { density: 300 })
	.resize(500, 500)
	.png()
	.toBuffer();

const iconSize = 112;
const gap = 28;
const icons = await Promise.all(['Yomu', 'Miru', 'Kiku', 'Hiku'].map((name) => icon(name, iconSize)));

await sharp(background)
	.composite([
		{ input: swift, left: 40, top: 70 },
		...icons.map((input, index) => ({ input, left: 562 + index * (iconSize + gap), top: 420 })),
	])
	.png()
	.toFile(new URL('../public/social.png', import.meta.url).pathname);

console.log('Wrote public/social.png');
