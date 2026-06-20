// Headless test harness for index.html's viewer logic.
// No browser libs available, so we mock a minimal DOM + fetch and run the REAL
// inline <script> from index.html against edge-case data, then assert.
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const INDEX = path.join(__dirname, '..', 'index.html');
const html = fs.readFileSync(INDEX, 'utf8');

// extract the last <script>...</script> (the app script)
const sOpen = html.lastIndexOf('<script>');
const sClose = html.lastIndexOf('</script>');
if (sOpen < 0 || sClose < 0) { console.error('no script found'); process.exit(2); }
const appScript = html.slice(sOpen + '<script>'.length, sClose);

// ---- mock DOM ----
function classList() {
  const s = new Set();
  return {
    _s: s,
    add: c => s.add(c),
    remove: c => s.delete(c),
    toggle: (c, f) => { if (f === undefined) { s.has(c) ? s.delete(c) : s.add(c); } else { f ? s.add(c) : s.delete(c); } return s.has(c); },
    contains: c => s.has(c),
  };
}
function el(extra = {}) {
  const e = {
    _html: '', _text: '', disabled: false, value: '', onclick: null, onchange: null,
    classList: classList(), dataset: {}, addEventListener() {},
    set innerHTML(v) { this._html = String(v); }, get innerHTML() { return this._html; },
    set textContent(v) { this._text = String(v); }, get textContent() { return this._text; },
    ...extra,
  };
  return e;
}

function makeDoc() {
  const ids = ['feedDate','ct-all','ct-job','ct-contest','ct-competition','stage','total','cur','dots','prev','next','day'];
  const byId = {}; ids.forEach(i => byId[i] = el());
  // pills
  const cats = ['all','job','contest','competition'];
  const pills = cats.map((c, i) => { const p = el(); p.dataset.cat = c; if (i === 0) p.classList.add('on'); return p; });
  const listeners = {};
  const doc = {
    _byId: byId, _pills: pills, _listeners: listeners,
    getElementById: id => byId[id] || (byId[id] = el()),
    querySelectorAll: sel => sel === '.pill' ? pills.slice() : [],
    addEventListener: (t, fn) => { (listeners[t] = listeners[t] || []).push(fn); },
  };
  return doc;
}

async function boot(fetchMap) {
  const doc = makeDoc();
  const fetchStub = async (file) => {
    if (!(file in fetchMap)) throw new Error('404 ' + file);
    return { json: async () => JSON.parse(JSON.stringify(fetchMap[file])) };
  };
  const out = {};
  const epilogue = `
    ;out.render=render; out.go=go; out.applyFilter=applyFilter; out.load=load;
    out.get=()=>({view, idx, filter, DATA});`;
  const fn = new Function('document', 'fetch', 'out', appScript + epilogue);
  fn(doc, fetchStub, out);
  // let init()'s async fetches resolve
  for (let i = 0; i < 6; i++) await new Promise(r => setTimeout(r, 0));
  return { doc, out };
}

// ---- assertion plumbing ----
let pass = 0, fail = 0; const fails = [];
function ok(cond, msg) { if (cond) pass++; else { fail++; fails.push(msg); } }
function eq(a, b, msg) { ok(a === b, `${msg} — expected ${JSON.stringify(b)} got ${JSON.stringify(a)}`); }

const card = d => d.doc._byId.stage._html;
const counter = d => `${d.doc._byId.cur._text} / ${d.doc._byId.total._text}`;
function key(d, k) { (d.doc._listeners.keydown || []).forEach(fn => fn({ key: k })); }

// future/past date helpers (YYYY-MM-DD)
const day = n => { const t = new Date(); t.setHours(0,0,0,0); t.setDate(t.getDate() + n);
  const p = x => String(x).padStart(2,'0'); return `${t.getFullYear()}-${p(t.getMonth()+1)}-${p(t.getDate())}`; };

const feed = (items) => ({ 'data/index.json': { dates: ['2026-06-19'] }, 'data/latest.json': { date: '2026-06-19', items } });

// =================== TESTS ===================
async function run() {
  // 1) normal nav
  {
    const d = await boot(feed([
      { category:'job', title:'A', org:'O1', url:'http://a', deadline:day(20), tags:['x'], summary:'sa' },
      { category:'contest', title:'B', org:'O2', url:'http://b', deadline:null, tags:[], summary:'' },
      { category:'competition', title:'C', org:'O3', url:'http://c', deadline:day(2), tags:['y','z'], summary:'sc' },
    ]));
    eq(counter(d), '1 / 3', '[nav] initial counter');
    ok(card(d).includes('>A<'), '[nav] first card title A');
    eq(d.doc._byId.prev.disabled, true, '[nav] prev disabled at start');
    eq(d.doc._byId.next.disabled, false, '[nav] next enabled at start');
    key(d, 'ArrowRight');
    eq(counter(d), '2 / 3', '[nav] after right counter');
    ok(card(d).includes('>B<'), '[nav] second card B');
    key(d, 'ArrowRight');
    eq(counter(d), '3 / 3', '[nav] third counter');
    eq(d.doc._byId.next.disabled, true, '[nav] next disabled at end');
    key(d, 'ArrowRight'); // no-op past end
    eq(counter(d), '3 / 3', '[nav] right past end is no-op');
    key(d, 'ArrowLeft');
    eq(counter(d), '2 / 3', '[nav] left goes back');
  }

  // 2) XSS escaping
  {
    const d = await boot(feed([
      { category:'job', title:'<script>alert(1)</script>', org:'A & B "C"', url:'http://x', deadline:null, tags:['<b>'], summary:`<img src=x onerror=1> & 'q'` },
    ]));
    const h = card(d);
    ok(!h.includes('<script>alert(1)</script>'), '[xss] raw script tag not present');
    ok(h.includes('&lt;script&gt;'), '[xss] title escaped');
    ok(h.includes('&amp;'), '[xss] ampersand escaped');
    ok(!h.includes('<img src=x onerror=1>'), '[xss] raw img not present');
  }

  // 3) missing fields
  {
    const d = await boot(feed([
      { category:'job', title:'No extras', url:'', deadline:null },
    ]));
    const h = card(d);
    ok(h.includes('상시 / 마감 미정'), '[missing] null deadline label');
    ok(!h.includes('class="tags"'), '[missing] no tags block when none');
    ok(!h.includes('class="summary"'), '[missing] no summary block when none');
    ok(!h.includes('원문 보기'), '[missing] no source link when url empty');
  }

  // 4) deadline variants
  {
    const variants = [
      [day(-1), '마감됨'],
      [day(0), '오늘 마감'],
      [day(2), 'D-2 마감'],
      [day(5), 'D-5 마감'],
      [day(10), 'D-10 마감'],
    ];
    for (const [dl, exp] of variants) {
      const d = await boot(feed([{ category:'job', title:'T', url:'http://t', deadline:dl }]));
      ok(card(d).includes(exp), `[dday] ${dl} -> ${exp}`);
    }
    // soon class for <=3, mid for <=7
    const dSoon = await boot(feed([{ category:'job', title:'T', url:'http://t', deadline:day(2) }]));
    ok(card(dSoon).includes('dday soon'), '[dday] <=3 has soon class');
    const dMid = await boot(feed([{ category:'job', title:'T', url:'http://t', deadline:day(5) }]));
    ok(card(dMid).includes('dday mid'), '[dday] <=7 has mid class');
  }

  // 5) empty feed
  {
    const d = await boot(feed([]));
    eq(counter(d), '0 / 0', '[empty] counter 0/0');
    ok(card(d).includes('새 항목이 없'), '[empty] empty-state message');
    eq(d.doc._byId.prev.disabled, true, '[empty] prev disabled');
    eq(d.doc._byId.next.disabled, true, '[empty] next disabled');
    eq(d.doc._byId['ct-all']._text, '0', '[empty] ct-all 0');
  }

  // 6) unknown category falls back, counts ok
  {
    const d = await boot(feed([
      { category:'job', title:'J', url:'http://j', deadline:null },
      { category:'weird', title:'W', url:'http://w', deadline:null },
    ]));
    eq(d.doc._byId['ct-all']._text, '2', '[unknown] ct-all counts all');
    eq(d.doc._byId['ct-job']._text, '1', '[unknown] ct-job 1');
    ok(card(d).includes('>J<'), '[unknown] renders first');
    // navigate to weird card, label should be raw category
    key(d, 'ArrowRight');
    ok(card(d).includes('weird'), '[unknown] unknown category label shown');
  }

  // 7) filter pills
  {
    const d = await boot(feed([
      { category:'job', title:'J1', url:'#', deadline:null },
      { category:'job', title:'J2', url:'#', deadline:null },
      { category:'contest', title:'K1', url:'#', deadline:null },
    ]));
    // click the contest pill
    const contestPill = d.doc._pills.find(p => p.dataset.cat === 'contest');
    contestPill.onclick();
    eq(counter(d), '1 / 1', '[filter] contest shows 1');
    ok(card(d).includes('>K1<'), '[filter] contest card');
    ok(contestPill.classList.contains('on'), '[filter] contest pill on');
    // back to all
    const allPill = d.doc._pills.find(p => p.dataset.cat === 'all');
    allPill.onclick();
    eq(counter(d), '1 / 3', '[filter] all shows 3 (idx reset)');
  }

  // 8) many items -> dots hidden
  {
    const items = Array.from({length: 45}, (_, i) => ({ category:'job', title:'T'+i, url:'#', deadline:null }));
    const d = await boot(feed(items));
    eq(counter(d), '1 / 45', '[many] counter 1/45');
    eq(d.doc._byId.dots._html, '', '[many] dots hidden when >40');
  }

  // 9) url sanitization
  {
    const dJs = await boot(feed([{ category:'job', title:'JS', url:'javascript:alert(1)', deadline:null }]));
    ok(!card(dJs).includes('원문 보기'), '[url] javascript: url dropped');
    ok(!card(dJs).includes('javascript:'), '[url] no javascript: in html');
    const dHttp = await boot(feed([{ category:'job', title:'H', url:'https://ok.com/x', deadline:null }]));
    ok(card(dHttp).includes('href="https://ok.com/x"'), '[url] https url kept');
    const dRel = await boot(feed([{ category:'job', title:'R', url:'/relative', deadline:null }]));
    ok(!card(dRel).includes('원문 보기'), '[url] relative url dropped');
  }

  // 10) arrow-key guard while focused in a form control
  {
    const d = await boot(feed([
      { category:'job', title:'A', url:'#', deadline:null },
      { category:'job', title:'B', url:'#', deadline:null },
    ]));
    (d.doc._listeners.keydown || []).forEach(fn => fn({ key:'ArrowRight', target:{ tagName:'SELECT' } }));
    eq(counter(d), '1 / 2', '[guard] arrow ignored when target is SELECT');
    key(d, 'ArrowRight');
    eq(counter(d), '2 / 2', '[guard] arrow works with no form target');
  }

  // 11) empty org renders no div
  {
    const d = await boot(feed([{ category:'job', title:'T', url:'#', deadline:null }]));
    ok(!card(d).includes('class="org"'), '[org] no empty org div when org missing');
  }

  // 12) day dropdown switches dataset
  {
    const fetchMap = {
      'data/index.json': { dates:['2026-06-19','2026-06-18'] },
      'data/latest.json': { date:'2026-06-19', items:[{ category:'job', title:'NEW', url:'#', deadline:null }] },
      'data/2026-06-18.json': { date:'2026-06-18', items:[
        { category:'contest', title:'OLD', url:'#', deadline:null },
        { category:'job', title:'OLD2', url:'#', deadline:null },
      ] },
    };
    const d = await boot(fetchMap);
    ok(card(d).includes('>NEW<'), '[day] latest shows newest');
    eq(d.doc._byId.feedDate._text, '2026-06-19', '[day] feedDate = newest');
    ok(d.doc._byId.day._html.includes('2026-06-18'), '[day] dropdown lists older date');
    d.doc._byId.day.value = '2026-06-18';
    await d.doc._byId.day.onchange();
    for (let i=0;i<4;i++) await new Promise(r=>setTimeout(r,0));
    eq(counter(d), '1 / 2', '[day] older day loaded (2 items)');
    ok(card(d).includes('>OLD<'), '[day] older day first card');
    eq(d.doc._byId.feedDate._text, '2026-06-18', '[day] feedDate updated on switch');
  }

  // 13) REAL data smoke test (the actual data/latest.json on disk)
  try {
    const real = JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'data', 'latest.json'), 'utf8'));
    const fm = { 'data/index.json': { dates: [real.date] }, 'data/latest.json': real };
    const d = await boot(fm);
    const n = real.items.length;
    eq(counter(d), `1 / ${n}`, '[real] counter matches real item count');
    ok(card(d).length > 0, '[real] first real card renders');
    for (let i = 1; i < n; i++) key(d, 'ArrowRight');
    eq(counter(d), `${n} / ${n}`, '[real] navigated through all real cards');
    ok(d.doc._byId.stage._html.includes('원문 보기') || n === 0, '[real] source links render');
  } catch (e) { ok(false, '[real] smoke test threw: ' + e.message); }

  // 14) malformed feed missing items key -> no crash, empty state
  {
    const fm = { 'data/index.json': { dates:['2026-06-19'] }, 'data/latest.json': { date:'2026-06-19' } };
    const d = await boot(fm);
    eq(counter(d), '0 / 0', '[malformed] missing items key -> 0/0 (no crash)');
    ok(card(d).includes('새 항목이 없'), '[malformed] empty state shown');
  }

  // ---- report ----
  console.log(`\n${'='.repeat(48)}`);
  console.log(`PASS ${pass}  FAIL ${fail}`);
  if (fails.length) { console.log('\nFAILURES:'); fails.forEach(f => console.log('  ✗ ' + f)); process.exitCode = 1; }
  else console.log('All viewer logic tests passed ✓');
}
run();
