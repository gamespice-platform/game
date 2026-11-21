// The web capture of the Nightly Performance contract: loads a game's web client in a real Chrome (a GPU box's, over CDP), plays it
// for --duration seconds after --warmup, and writes one perf report v1 (platform=web) from the page's requestAnimationFrame
// frame times, the WebGL renderer string and the JS heap. A software renderer (SwiftShader, llvmpipe) exits 4: its frame times say
// nothing about a player's machine.
//
//   gpu.sh cdp-run --serve 8099 -- node dot_game_perf_web.mjs --url 'http://127.0.0.1:8099/embed.html?server=ws://127.0.0.1:6074'
//       --game fc --out report.json [--duration 20] [--warmup 8] [--bots N] [--map M] [--role client] [--commit SHA]
//
// dot_game_perf.sh runs it for a game whose tools/perf.sh sets PERF_WEB_URL (the page, with its server already up). Env GPU_CDP_URL
// (set by cdp-run) or CDP names the DevTools endpoint; PLAYWRIGHT_CORE the playwright-core index.js.
// Exit: 0 report written, 2 bad arguments, 4 software renderer, 1 the page never ran.
import { writeFileSync } from 'node:fs';
const a = new Map();
for (let i = 2; i < process.argv.length; i += 2) a.set(process.argv[i].replace(/^--/, ''), process.argv[i + 1]);
const url = a.get('url'), out = a.get('out');
if (!url || !out) { console.error('perf web: --url and --out are required'); process.exit(2); }
const game = a.get('game') ?? 'unknown', duration = +(a.get('duration') ?? 20), warmup = +(a.get('warmup') ?? 8);
const pw = (await import(process.env.PLAYWRIGHT_CORE ?? '/home/christian/.local/share/mcp/playwright-mcp/node_modules/playwright-core/index.js')).default;
const browser = await pw.chromium.connectOverCDP(process.env.CDP ?? process.env.GPU_CDP_URL ?? 'http://127.0.0.1:9222');
const context = browser.contexts()[0] ?? await browser.newContext();
const page = await context.newPage();
await page.addInitScript(() => {
	window.__perfFrames = [];
	let last = 0;
	const tick = (t) => { if (last) window.__perfFrames.push([t, t - last]); last = t; requestAnimationFrame(tick); };
	requestAnimationFrame(tick);
});
await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 120000 });
await page.waitForTimeout(warmup * 1000);
const t0 = await page.evaluate(() => ({ n: window.__perfFrames.length }));
const heap0 = await page.evaluate(() => performance.memory?.usedJSHeapSize ?? 0);
await page.waitForTimeout(duration * 1000);
const r = await page.evaluate((from) => {
	const gl = document.createElement('canvas').getContext('webgl2');
	const ext = gl?.getExtension('WEBGL_debug_renderer_info');
	return { ms: window.__perfFrames.slice(from).map((f) => f[1]), gpu: ext ? gl.getParameter(ext.UNMASKED_RENDERER_WEBGL) : '',
		heap: performance.memory?.usedJSHeapSize ?? 0, engine: window.__TMC_ENGINE__ ?? null, natives: window.__TMC_NATIVES__ ?? null,
		isolated: self.crossOriginIsolated === true, res: `${innerWidth}x${innerHeight}`, ua: navigator.userAgent };
}, t0.n);
await page.close();
await browser.close().catch(() => {});
if (!r.gpu || /swiftshader|llvmpipe|software|softpipe/i.test(r.gpu)) { console.error(`perf web: refusing a software renderer ('${r.gpu}')`); process.exit(4); }
if (r.ms.length < 10) { console.error(`perf web: only ${r.ms.length} frames in ${duration} s; the page did not render`); process.exit(1); }
const s = [...r.ms].sort((x, y) => x - y), q = (p) => s[Math.min(s.length - 1, Math.floor(p * s.length))];
const avg = s.reduce((x, y) => x + y, 0) / s.length, MB = (b) => +(b / 1048576).toFixed(1);
const budget = 16.7;
const rep = {
	schema: 'gamespice.perf-report', schema_version: 1, schema_minor: 1, made_utc: new Date().toISOString(), game_id: game,
	build: { commit: a.get('commit') ?? 'unknown', source: a.get('commit') ? 'git' : 'unknown' },
	platform: 'web', role: a.get('role') ?? 'client', scene: new URL(url).pathname.split('/').pop() || 'embed.html',
	map: a.get('map') ?? '', bots: +(a.get('bots') ?? 0), resolution: r.res, gpu: r.gpu, os: r.ua, renderer: 'webgl2', duration_s: duration,
	tags: [`engine=${r.engine}`, `natives=${r.natives}`, `isolated=${r.isolated}`],
	frame: { count: s.length, ms: { min: s[0], avg: +avg.toFixed(3), p50: q(0.5), p95: q(0.95), p99: q(0.99), max: s[s.length - 1] },
		fps_avg: +(1000 / avg).toFixed(1), budget_ms: budget, over_budget: s.filter((x) => x > budget * 1.5).length },
	memory: { wasm_heap_mb: { start: MB(heap0), end: MB(r.heap) } },
	notes: ['requestAnimationFrame deltas on a real GPU browser: vsync caps fps at the display rate, so p50 near 16.7 ms says "at refresh", not headroom'],
};
writeFileSync(out, JSON.stringify(rep, null, 1));
console.log(out);
