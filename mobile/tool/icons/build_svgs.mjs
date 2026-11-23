// Writes the Kemlock logo masters into assets/brand/ (the keyhole K, from the
// owner's design canvas). Run with `node tool/icons/build_svgs.mjs` from
// mobile/; render.sh then draws the platform rasters from them.
//
// The mark is drawn in a 100 x 100 box: a rounded tile in a vertical gunmetal
// gradient, and on it a K in the accent colour, translated 2 left, with a
// keyhole cut in its stem. The design adds a noise filter to the tile and a
// shadow to the K; SVG filters are skipped here because rasterisers and
// flutter_svg handle them badly. The large icon fakes the K's shadow with a few
// offset copies, and the small one (<= 48) drops it, as the design does.
//
// The wordmark's "emlock" is set in Geist SemiBold and turned into outlines
// here (no <text>), so it draws the same everywhere without the font.
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const mobile = join(here, '..', '..');
const out = join(mobile, 'assets', 'brand');
mkdirSync(out, { recursive: true });

const ACCENT = '#5AA9FF';
const ACCENT_INK = '#1F6FD1';

const n = (v) => String(Math.round(v * 1000) / 1000);

const gradient = (id, y1, y2, stops) =>
  `<linearGradient id="${id}" gradientUnits="userSpaceOnUse" x1="0" y1="${y1}" x2="0" y2="${y2}">` +
  stops.map(([o, c]) => `<stop offset="${o}" stop-color="${c}"/>`).join('') +
  `</linearGradient>`;

const gunmetal = (id, y2 = 100) =>
  gradient(id, 0, y2, [
    [0, '#5E646E'],
    [0.44, '#353A41'],
    [0.5, '#15181C'],
    [0.57, '#262A30'],
    [0.85, '#1E2126'],
    [1, '#16181C'],
  ]);

const steel = gradient('steel', 18, 82, [
  [0, '#FAFBFD'],
  [0.28, '#DCE1E8'],
  [0.48, '#A4ACB8'],
  [0.52, '#5D6673'],
  [0.58, '#8F98A4'],
  [0.78, '#D3D8DF'],
  [0.92, '#EEF1F4'],
  [1, '#A9B0BA'],
]);
const gun = gradient('gun', 18, 82, [
  [0, '#5A606A'],
  [0.45, '#3A3F47'],
  [0.5, '#16191D'],
  [0.58, '#2C3036'],
  [0.85, '#4A5059'],
  [1, '#2A2E34'],
]);

// The keyhole: a circle of radius 4.6 at (32.5, 45) over a flared slot, y 47..57,
// half a unit wider at the bottom. Joined into one outline so it can be cut
// from the stem with even-odd fill.
function keyholePath(cx = 32.5) {
  const cy = 45;
  const r = 4.6;
  const bx = 35.8 - 32.5; // slot half-width at the bottom
  const ax = 34.6 - 32.5; // and at y = 47
  // The slot's right edge, from (cx+bx, 57) up towards (cx+ax, 47), meets the circle here.
  let lo = 0;
  let hi = 1;
  for (let i = 0; i < 60; i++) {
    const t = (lo + hi) / 2;
    const x = cx + bx + (ax - bx) * t - cx;
    const y = 57 - 10 * t - cy;
    if (x * x + y * y > r * r) lo = t;
    else hi = t;
  }
  const px = bx + (ax - bx) * lo;
  const py = 57 - 10 * lo;
  return `M${n(cx - bx)} 57H${n(cx + bx)}L${n(cx + px)} ${n(py)}A${r} ${r} 0 1 0 ${n(cx - px)} ${n(py)}Z`;
}
const stemRect = 'M28 20h9a4 4 0 0 1 4 4v52a4 4 0 0 1-4 4h-9a4 4 0 0 1-4-4V24a4 4 0 0 1 4-4z';
const chevron = 'M72 26L48 50l24 24';

// The K in the 100-unit box, translated 2 left. `hole`: 'cut' makes the keyhole
// transparent, a colour fills it with that (the tile's gradient, as the design
// does), null leaves it out (favicon).
function glyph({ fill, hole, shadow = false, extra = '' }) {
  const k = (f, o = '') =>
    `<path${o} fill="${f}" fill-rule="evenodd" d="${stemRect}${hole === 'cut' ? keyholePath() : ''}"/>` +
    `<path${o} d="${chevron}" fill="none" stroke="${f}" stroke-width="16" stroke-linecap="round" stroke-linejoin="round"/>`;
  let s = '';
  if (shadow) {
    for (const dy of [0.5, 1, 1.5]) s += `<g transform="translate(0 ${dy})">${k('#000', ' opacity="0.16"')}</g>`;
  }
  s += k(fill);
  if (hole && hole !== 'cut') {
    s += `<circle cx="32.5" cy="45" r="4.6" fill="${hole}"/><path d="M30.4 47l-1.2 10h6.6l-1.2-10z" fill="${hole}"/>`;
  }
  return `<g transform="translate(-2 0)">${s}</g>${extra}`;
}

const svg = (viewBox, body, defs = '', label = 'Kemlock') =>
  `<svg xmlns="http://www.w3.org/2000/svg" viewBox="${viewBox}" role="img" aria-label="${label}">` +
  (defs ? `<defs>${defs}</defs>` : '') +
  body +
  `</svg>\n`;

const files = {};

// The app icon: the rounded tile, the K, the keyhole in the tile's gradient.
files['kemlock-icon.svg'] = svg(
  '0 0 100 100',
  `<rect width="100" height="100" rx="22.5" fill="url(#tile)"/>` + glyph({ fill: ACCENT, hole: 'url(#tile)', shadow: true }),
  gunmetal('tile'),
);
// 48 and under: no shadow.
files['kemlock-icon-small.svg'] = svg(
  '0 0 100 100',
  `<rect width="100" height="100" rx="22.5" fill="url(#tile)"/>` + glyph({ fill: ACCENT, hole: 'url(#tile)' }),
  gunmetal('tile'),
);
// The 16 and 32 favicon: no keyhole.
files['kemlock-favicon.svg'] = svg(
  '0 0 100 100',
  `<rect width="100" height="100" rx="22.5" fill="url(#tile)"/>` + glyph({ fill: ACCENT, hole: null }),
  gunmetal('tile'),
);
// iOS and maskable icons: the tile fills the square, the platform rounds it.
files['kemlock-icon-square.svg'] = svg(
  '0 0 100 100',
  `<rect width="100" height="100" fill="url(#tile)"/>` + glyph({ fill: ACCENT, hole: 'url(#tile)', shadow: true }),
  gunmetal('tile'),
);
// Android's round launcher icon, for launchers without adaptive icons.
files['kemlock-icon-round.svg'] = svg(
  '0 0 100 100',
  `<circle cx="50" cy="50" r="50" fill="url(#tile)"/>` +
    `<g transform="translate(50 50) scale(0.9) translate(-50 -50)">${glyph({ fill: ACCENT, hole: 'url(#tile)' })}</g>`,
  gunmetal('tile'),
);

// Android adaptive icon layers, on the 108 dp canvas. The K sits inside the
// 66 dp safe zone; the keyhole is cut, so the background shows through it.
const AD = 0.84;
const adaptiveGlyph = (fill) =>
  `<g transform="translate(54 54) scale(${AD}) translate(-50 -50)">${glyph({ fill, hole: 'cut' })}</g>`;
files['kemlock-icon-foreground.svg'] = svg('0 0 108 108', adaptiveGlyph(ACCENT));
files['kemlock-icon-background.svg'] = svg('0 0 108 108', `<rect width="108" height="108" fill="url(#tile)"/>`, gunmetal('tile', 108));
// Android 13 themed icons: one colour, the system tints it from the alpha.
files['kemlock-icon-monochrome.svg'] = svg('0 0 108 108', adaptiveGlyph('#000'));

// The K alone, for in-app use on a themed ground (keyhole cut).
files['kemlock-mark-dark.svg'] = svg('20 16 60 68', glyph({ fill: ACCENT, hole: 'cut' }));
files['kemlock-mark-light.svg'] = svg('20 16 60 68', glyph({ fill: ACCENT_INK, hole: 'cut' }));

// ---- The wordmark: the K, then "emlock" in Geist SemiBold as outlines.

function loadFont(path) {
  const b = readFileSync(path);
  const dv = new DataView(b.buffer, b.byteOffset, b.byteLength);
  const tables = {};
  for (let i = 0; i < dv.getUint16(4); i++) {
    const o = 12 + i * 16;
    tables[String.fromCharCode(...b.subarray(o, o + 4))] = dv.getUint32(o + 8);
  }
  const upm = dv.getUint16(tables.head + 18);
  const longLoca = dv.getInt16(tables.head + 50) === 1;
  const numHM = dv.getUint16(tables.hhea + 34);
  const loca = (g) => (longLoca ? dv.getUint32(tables.loca + g * 4) : dv.getUint16(tables.loca + g * 2) * 2);

  // cmap, format 4 or 12
  const cm = tables.cmap;
  let sub = null;
  for (let i = 0; i < dv.getUint16(cm + 2); i++) {
    const o = cm + dv.getUint32(cm + 4 + i * 8 + 4);
    const f = dv.getUint16(o);
    if (f === 12 || (f === 4 && !sub)) sub = o;
    if (f === 12) break;
  }
  const glyphId = (cp) => {
    const f = dv.getUint16(sub);
    if (f === 12) {
      for (let i = 0; i < dv.getUint32(sub + 12); i++) {
        const o = sub + 16 + i * 12;
        const s = dv.getUint32(o);
        const e = dv.getUint32(o + 4);
        if (cp >= s && cp <= e) return dv.getUint32(o + 8) + cp - s;
      }
      return 0;
    }
    const segX2 = dv.getUint16(sub + 6);
    const endO = sub + 14;
    const startO = endO + segX2 + 2;
    const deltaO = startO + segX2;
    const rangeO = deltaO + segX2;
    for (let i = 0; i < segX2 / 2; i++) {
      if (cp <= dv.getUint16(endO + i * 2)) {
        const s = dv.getUint16(startO + i * 2);
        if (cp < s) return 0;
        const ro = dv.getUint16(rangeO + i * 2);
        if (ro === 0) return (cp + dv.getInt16(deltaO + i * 2)) & 0xffff;
        const g = dv.getUint16(rangeO + i * 2 + ro + (cp - s) * 2);
        return g === 0 ? 0 : (g + dv.getInt16(deltaO + i * 2)) & 0xffff;
      }
    }
    return 0;
  };
  const advance = (g) => dv.getUint16(tables.hmtx + Math.min(g, numHM - 1) * 4);

  // Returns contours of {x, y, on} points, in font units; composites are applied.
  function contours(g, ax = 0, ay = 0, sx = 1, sy = 1) {
    const start = loca(g);
    if (start === loca(g + 1)) return [];
    const o = tables.glyf + start;
    const nc = dv.getInt16(o);
    if (nc < 0) {
      const res = [];
      let p = o + 10;
      for (;;) {
        const flags = dv.getUint16(p);
        const gi = dv.getUint16(p + 2);
        p += 4;
        let dx;
        let dy;
        if (flags & 1) {
          dx = dv.getInt16(p);
          dy = dv.getInt16(p + 2);
          p += 4;
        } else {
          dx = dv.getInt8(p);
          dy = dv.getInt8(p + 1);
          p += 2;
        }
        let a = 1;
        let d = 1;
        if (flags & 8) {
          a = d = dv.getInt16(p) / 16384;
          p += 2;
        } else if (flags & 0x40) {
          a = dv.getInt16(p) / 16384;
          d = dv.getInt16(p + 2) / 16384;
          p += 4;
        } else if (flags & 0x80) throw new Error('2x2 composite glyphs are not supported');
        res.push(...contours(gi, ax + dx * sx, ay + dy * sy, sx * a, sy * d));
        if (!(flags & 0x20)) break;
      }
      return res;
    }
    const ends = [];
    let p = o + 10;
    for (let i = 0; i < nc; i++, p += 2) ends.push(dv.getUint16(p));
    const np = ends[nc - 1] + 1;
    p += 2 + dv.getUint16(p);
    const fl = [];
    while (fl.length < np) {
      const f = dv.getUint8(p++);
      fl.push(f);
      if (f & 8) for (let r = dv.getUint8(p++); r > 0; r--) fl.push(f);
    }
    const xs = [];
    let v = 0;
    for (let i = 0; i < np; i++) {
      if (fl[i] & 2) {
        const d = dv.getUint8(p++);
        v += fl[i] & 16 ? d : -d;
      } else if (!(fl[i] & 16)) {
        v += dv.getInt16(p);
        p += 2;
      }
      xs.push(v);
    }
    const ys = [];
    v = 0;
    for (let i = 0; i < np; i++) {
      if (fl[i] & 4) {
        const d = dv.getUint8(p++);
        v += fl[i] & 32 ? d : -d;
      } else if (!(fl[i] & 32)) {
        v += dv.getInt16(p);
        p += 2;
      }
      ys.push(v);
    }
    const res = [];
    let s = 0;
    for (const e of ends) {
      const c = [];
      for (let i = s; i <= e; i++) c.push({ x: ax + xs[i] * sx, y: ay + ys[i] * sy, on: !!(fl[i] & 1) });
      res.push(c);
      s = e + 1;
    }
    return res;
  }
  return { upm, glyphId, advance, contours };
}

// One contour of quadratic points as SVG path data, mapped through (x, y) => [x', y'].
function contourPath(c, map) {
  // Make the start an on-curve point.
  let pts = c;
  if (!pts[0].on) {
    const last = pts[pts.length - 1];
    if (last.on) pts = [last, ...pts.slice(0, -1)];
    else pts = [{ x: (pts[0].x + last.x) / 2, y: (pts[0].y + last.y) / 2, on: true }, ...pts];
  }
  const m = (p) => map(p.x, p.y).map(n).join(' ');
  let d = `M${m(pts[0])}`;
  let i = 1;
  const len = pts.length;
  while (i <= len) {
    const p = pts[i % len];
    if (p.on) {
      d += `L${m(p)}`;
      i++;
    } else {
      const next = pts[(i + 1) % len];
      const end = next.on ? next : { x: (p.x + next.x) / 2, y: (p.y + next.y) / 2, on: true };
      d += `Q${m(p)} ${m(end)}`;
      i += next.on ? 2 : 1;
    }
  }
  return d + 'Z';
}

const font = loadFont(join(mobile, 'assets', 'fonts', 'Geist-SemiBold.ttf'));
const SIZE = 86;
const scale = SIZE / font.upm;
// Where Chromium puts each letter of <text x="82" font-size="86"
// font-weight="600" letter-spacing="-2.6"> set in this Geist SemiBold (read
// with getStartPositionOfChar), which includes the font's kerning.
const LETTER_X = [82, 129.359, 202.531, 224.781, 273.172, 319.594];
let textD = '';
let wordEnd = 0;
'emlock'.split('').forEach((ch, i) => {
  const g = font.glyphId(ch.codePointAt(0));
  for (const c of font.contours(g)) {
    textD += contourPath(c, (x, y) => {
      wordEnd = Math.max(wordEnd, LETTER_X[i] + x * scale);
      return [LETTER_X[i] + x * scale, 80 - y * scale];
    });
  }
});

// The K here is 2 left of the icon's, which `glyph` already applies; the
// wordmark's K sits at x 22, as in the design.
const wordmark = (accent, textFill, defs) =>
  svg(
    `18 12 ${n(Math.ceil(wordEnd) + 2 - 18)} 76`,
    glyph({ fill: accent, hole: 'cut' }) + `<path fill="${textFill}" d="${textD}"/>`,
    defs,
    'Kemlock',
  );
files['kemlock-wordmark-dark.svg'] = wordmark(ACCENT, 'url(#steel)', steel);
files['kemlock-wordmark-light.svg'] = wordmark(ACCENT_INK, 'url(#gun)', gun);

for (const [name, body] of Object.entries(files)) writeFileSync(join(out, name), body);
console.log(`wrote ${Object.keys(files).length} files to ${out}; wordmark ink ends at x=${n(wordEnd)}`);
