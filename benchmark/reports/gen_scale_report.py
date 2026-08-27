#!/usr/bin/env python3
"""Generate benchmark_report_scale.html from results_raw.json"""
import json

with open(r'E:\sqlite-cuda\sqlite\results_raw.json') as f:
    R = json.load(f)

LABELS = ['S1','S2','S3','S4','S5','E1','E2','E3','E4','E5','E6','E7','E8','E9','E10','E11','E12']
QUERIES = [
    ('S1','age = 30'),('S2','score > 50'),('S3','age >= 25 AND score <= 75'),
    ('S4','age > 30 AND score < 80 AND category = 5'),('S5','value >= 1000 AND value < 5000'),
    ('E1','age > 999 (no match)'),('E2','age >= 0 (all)'),('E3','value = 0'),
    ('E4','value = 9999'),('E5','age < 30'),('E6','age <= 29'),('E7','age <= 30'),
    ('E8','score = 0'),('E9','score > 99 (no match)'),('E10','category = 7'),
    ('E11','age = 30 AND score = 30'),('E12','6 conditions'),
]
SCALES = [50,100,250,500,750]
MODES = ['disk','mem']
CONFIGS_ORDER = ['cpu','nopipe','pipe5','pipe10','pipe20']
CONFIG_NAMES = {
    'cpu':'CPU','nopipe':'GPU non-pipe (10M)','pipe5':'GPU pipe 5M',
    'pipe10':'GPU pipe 10M','pipe20':'GPU pipe 20M','pip50':'GPU pipe 50M (OOM)',
}

def get(scale, mode, cfg):
    key = f'{scale}m_{mode}_{cfg}'
    d = R.get(key)
    if not d or d['rc'] != 0:
        return [None]*17
    ts = d['times']
    return [float(x) if x else None for x in ts]

def fmt(v, nd=2):
    if v is None: return '—'
    return f'{v:.{nd}f}'

# ---------------- Build tables ----------------
def config_table_header(extra_cols=()):
    cols = ['CPU','GPU non-pipe<br>10M','GPU pipe<br>5M','GPU pipe<br>10M','GPU pipe<br>20M','GPU pipe<br>50M']
    return cols

def build_table(scale, mode):
    """17-row table of times by config."""
    rows = []
    cols = ['cpu','nopipe','pipe5','pipe10','pipe20']
    for i, (lbl, descr) in enumerate(QUERIES):
        vals = [get(scale, mode, c)[i] for c in cols]
        best_i = None
        nonnull = [v for v in vals if v is not None]
        if nonnull:
            best_i = vals.index(min(nonnull))
        cells = ''
        for j, v in enumerate(vals):
            cls = ' class="best"' if j == best_i else ''
            cells += f'<td{cls}>{fmt(v)}</td>'
        rows.append(f'<tr><td>{lbl}</td><td><code>{descr}</code></td>{cells}</tr>')
    head = '<tr><th>#</th><th>WHERE clause</th>' + ''.join(f'<th>{c}</th>' for c in config_table_header()) + '</tr>'
    return f'<table>{head}{"".join(rows)}</table>'

def speedup_table(scale, mode, best_cfg='pipe5'):
    rows = []
    for i, (lbl, descr) in enumerate(QUERIES):
        cpu = get(scale, mode, 'cpu')[i]
        best = get(scale, mode, best_cfg)[i]
        if cpu and best:
            su = cpu/best
            rows.append(f'<tr><td>{lbl}</td><td><code>{descr}</code></td><td>{fmt(cpu)}</td><td>{fmt(best)}</td><td><strong>{fmt(su,2)}x</strong></td></tr>')
        else:
            rows.append(f'<tr><td>{lbl}</td><td><code>{descr}</code></td><td>{fmt(cpu)}</td><td>{fmt(best)}</td><td>—</td></tr>')
    head = '<tr><th>#</th><th>WHERE clause</th><th>CPU (s)</th><th>GPU pipe5 (s)</th><th>Speedup</th></tr>'
    return f'<table>{head}{"".join(rows)}</table>'

# JS data for scale-progression charts
def js_arrays():
    """Return dict of {cfg: {mode: [scale->avg-over-queries-of-speedup-or-time]}}"""
    out = {}
    for cfg in CONFIGS_ORDER:
        out[cfg] = {'disk': [], 'mem': []}
        for mode in MODES:
            for scale in SCALES:
                times = get(scale, mode, cfg)
                valid = [t for t in times if t is not None]
                avg = sum(valid)/len(valid) if valid else None
                out[cfg][mode].append(avg)
    return out

data = js_arrays()
js_data = {cfg: {m: data[cfg][m] for m in MODES} for cfg in CONFIGS_ORDER}

# Average rows per scale for one config
def avg_row(scale, mode, cfg):
    t = get(scale, mode, cfg)
    v = [x for x in t if x is not None]
    return sum(v)/len(v) if v else None

# Per-query per-scale speedup for E12 and S4 (showcase charts)
e12_speedup_disk = []
e12_speedup_mem = []
s4_speedup_disk = []
s4_speedup_mem = []
for scale in SCALES:
    cpu_d = get(scale,'disk','cpu')[11]
    p5_d = get(scale,'disk','pipe5')[11]
    cpu_m = get(scale,'mem','cpu')[11]
    p5_m = get(scale,'mem','pipe5')[11]
    e12_speedup_disk.append(cpu_d/p5_d if cpu_d and p5_d else None)
    e12_speedup_mem.append(cpu_m/p5_m if cpu_m and p5_m else None)
    cpu_d2 = get(scale,'disk','cpu')[3]
    p5_d2 = get(scale,'disk','pipe5')[3]
    cpu_m2 = get(scale,'mem','cpu')[3]
    p5_m2 = get(scale,'mem','pipe5')[3]
    s4_speedup_disk.append(cpu_d2/p5_d2 if cpu_d2 and p5_d2 else None)
    s4_speedup_mem.append(cpu_m2/p5_m2 if cpu_m2 and p5_m2 else None)

# Build per-scale average time table for CPU vs pipe5
avg_table_rows = ''
for mode in MODES:
    modename = 'On-disk' if mode=='disk' else 'In-memory'
    for scale in SCALES:
        cpu = avg_row(scale, mode, 'cpu')
        np10 = avg_row(scale, mode, 'nopipe')
        p5 = avg_row(scale, mode, 'pipe5')
        p10 = avg_row(scale, mode, 'pipe10')
        p20 = avg_row(scale, mode, 'pipe20')
        sp = cpu/p5 if cpu and p5 else None
        spnp = cpu/np10 if cpu and np10 else None
        avg_table_rows += (
            f'<tr><td>{modename}</td><td>{scale}M</td>'
            f'<td>{fmt(cpu)}</td><td>{fmt(np10)}</td><td>{fmt(p10)}</td><td class="best">{fmt(p5)}</td><td>{fmt(p20)}</td>'
            f'<td class="worst">OOM</td>'
            f'<td>{fmt(sp,2)}x</td><td>{fmt(spnp,2)}x</td></tr>'
        )

miss = '<td class="worst">OOM</td>'

def full_avg_table():
    rows = ''
    for mode in MODES:
        modename = 'On-disk' if mode=='disk' else 'In-memory'
        for scale in SCALES:
            rows += f'<tr><td>{modename}</td><td>{scale}M</td>'
            for cfg in CONFIGS_ORDER:
                a = avg_row(scale, mode, cfg)
                rows += f'<td class="best">{fmt(a)}</td>' if cfg=='pipe5' and a else f'<td>{fmt(a)}</td>'
            # pipe50
            rows += miss + '</tr>'
    return rows

# Build per-scale, per-mode, per-query full tables as sections
sections = ''
for scale in SCALES:
    for mode in MODES:
        modename = 'On-Disk' if mode=='disk' else 'In-Memory'
        sections += f'''
<h2>{scale}M Rows — {modename} (17 queries)</h2>
{build_table(scale, mode)}
<h4>Speedup vs CPU (pipe 5M)</h4>
{speedup_table(scale, mode, 'pipe5')}
'''

html = f'''<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>SQLite GPU Acceleration — Scale Progression Report (50M → 750M)</title>
<script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.0/dist/chart.umd.min.js"></script>
<style>
  body {{ font-family: -apple-system, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; margin:0; padding:24px; background:#f5f6fa; color:#1a1a2e; }}
  h1 {{ font-size:26px; border-bottom:3px solid #4b7bec; padding-bottom:8px; }}
  h2 {{ font-size:19px; margin-top:44px; color:#2f3542; }}
  h4 {{ font-size:14px; margin-top:20px; color:#57606f; }}
  .meta {{ color:#57606f; font-size:13px; margin-bottom:20px; }}
  .card {{ background:#fff; border-radius:10px; padding:20px; margin:18px 0; box-shadow:0 2px 8px rgba(0,0,0,.06); }}
  table {{ border-collapse:collapse; width:100%; font-size:12.5px; }}
  th,td {{ border:1px solid #dfe4ea; padding:5px 7px; text-align:right; }}
  th {{ background:#4b7bec; color:#fff; }}
  td:first-child, th:first-child, td:nth-child(2), th:nth-child(2) {{ text-align:left; }}
  tr:nth-child(even) {{ background:#fafbfc; }}
  .best {{ background:#d4edda !important; font-weight:700; color:#155724; }}
  .worst {{ background:#f8d7da !important; color:#721c24; }}
  .chartwrap {{ max-width:900px; margin:12px auto; }}
  .note {{ font-size:12px; color:#57606f; font-style:italic; }}
  code {{ background:#f1f2f6; padding:1px 5px; border-radius:3px; font-size:11.5px; }}
</style>
</head>
<body>
<h1>SQLite GPU Acceleration — Scale Progression Report</h1>
<div class="meta">
  <strong>Hardware:</strong> NVIDIA RTX 4000 Ada (20GB) &nbsp;|&nbsp; <strong>DBs:</strong> 50M / 100M / 250M / 500M / 750M rows (5 cols)<br>
  <strong>Configs:</strong> CPU &bull; GPU non-pipe 10M &bull; GPU pipe 5M / 10M / 20M / 50M &bull; On-disk (SSD) and In-memory (:memory:)<br>
  <strong>Queries:</strong> 17 × <code>SELECT COUNT(*)</code> with filters; all configs return identical correct results.
</div>

<div class="card">
<h2>1. Average Full-Scan Time by Data Size</h2>
<p class="note">Average across the 17 queries. pipe50 OOM'd at every scale (host buffers too large).</p>
<div class="chartwrap"><canvas id="chartAvg"></canvas></div>
<h4>Table (avg seconds per query)</h4>
<table>
<tr><th>Mode</th><th>Rows</th><th>CPU</th><th>GPU non-pipe 10M</th><th>GPU pipe 10M</th><th>GPU pipe 5M</th><th>GPU pipe 20M</th><th>GPU pipe 50M</th><th>Speedup (CPU/pipe5)</th><th>Speedup (CPU/nopipe)</th></tr>
{avg_table_rows}
</table>
</div>

<div class="card">
<h2>2. Speedup vs CPU by Data Size</h2>
<div class="chartwrap"><canvas id="chartSpeedup"></canvas></div>
</div>

<div class="card">
<h2>3. Showcase Queries — Speedup Scaling</h2>
<p class="note"><strong>S4</strong> (3 conditions) and <strong>E12</strong> (6 conditions) — where GPU parallelism shines most.</p>
<div class="chartwrap"><canvas id="chartE12"></canvas></div>
<div class="chartwrap"><canvas id="chartS4"></canvas></div>
</div>

<div class="card">
<h2>4. Methodology</h2>
<ul>
  <li>Each config×scale×mode run executes all 17 queries; <code>.timer ON</code> reports real seconds; parsed from stdout.</li>
  <li>In-memory mode: <code>ATTACH ':memory:'</code>, <code>CREATE TABLE mem.gpu_test AS SELECT * FROM main.gpu_test</code>, then queries on <code>mem.gpu_test</code>.</li>
  <li>On-disk mode: queries run directly on the 5.2KB-page-file DB read from SSD (SQLite default 2MB page cache → cold reads per query).</li>
  <li>Data layout: <code>id=x, age=20+(x%60), score=(x*17)%100, category=x%10, value=(x*13)%10000</code>, x=1..N.</li>
  <li>GPU path supports int comparisons + AND chains + COUNT(*) aggregate shortcut only.</li>
  <li>pipe50 OOM (needs 4GB host buffers); excluded.</li>
</ul>
</div>

<div class="card">
<h2>5. Full Per-Query Results — Every Scale × Mode</h2>
{sections}
</div>

<div class="card">
<h2>6. Key Findings</h2>
<ul>
  <li>GPU pipelined (5M) is the fastest config across <strong>all</strong> scales — absolute time grows roughly linearly (I/O / scan bound).</li>
  <li>GPU speedup vs CPU <strong>increases with data size</strong> for multi-condition queries (E12/S4), while single-condition speedup stays ~1.3-1.7x.</li>
  <li>In-memory removes the disk-I/O floor: GPU drops to ~9.5s at 500M, versus ~11.1s on-disk.</li>
  <li>CPU is compute-bound: in-memory vs disk changes CPU time little.</li>
  <li>Batch 5M beats 10M beats 20M; 50M OOMs. Smaller batches hide GPU latency better with pipelining.</li>
</ul>
</div>

<script>
const scales = [50,100,250,500,750];
const cfgData = {json.dumps(js_data)};
window.__RAW__ = {json.dumps(R)};

const colors = {{ cpu:'#eb3b5a', nopipe:'#f39c12', pipe5:'#20bf6b', pipe10:'#0984e3', pipe20:'#8e44ad' }};

function mkAvgChart(canvasId, modeTitle) {{
  const ctx = document.getElementById(canvasId).getContext('2d');
  const ds = [];
  for (const [cfg, v] of Object.entries(cfgData)) {{
    for (const mode of ['disk','mem']) {{
      ds.push({{
        label: cfg.toUpperCase()+' '+mode,
        data: v[mode].map(x=>x? +x.toFixed(3):null),
        borderColor: colors[cfg],
        backgroundColor: colors[cfg]+'33',
        borderDash: mode==='mem'? [6,4] : [],
        fill:false, tension:.25, pointRadius:4
      }});
    }}
  }}
  new Chart(ctx, {{ type:'line', data:{{ labels: scales.map(s=>s+'M'), datasets: ds }},
    options:{{ scales:{{ y:{{ title:{{ display:true, text:'Avg time (s)' }} }} }} }} }});
}}

function mkSpeedupChart(canvasId, cfg) {{
  const ctx = document.getElementById(canvasId).getContext('2d');
  const ds = [];
  for (const mode of ['disk','mem']) {{
    const sp = scales.map((s,ix)=>{{
      const c = cfgData['cpu'][mode][ix];
      const b = cfgData[cfg][mode][ix];
      return (c&&b)? +(c/b).toFixed(2): null;
    }});
    ds.push({{ label: cfg.toUpperCase()+' vs CPU '+mode, data: sp, borderColor: colors[cfg], backgroundColor: colors[cfg]+'33', borderDash: mode==='mem'?[6,4]:[], fill:false, tension:.25, pointRadius:4 }});
  }}
  new Chart(ctx, {{ type:'line', data:{{ labels: scales.map(s=>s+'M'), datasets: ds }},
    options:{{ scales:{{ y:{{ title:{{ display:true, text:'Speedup (x)' }} }} }} }} }});
}}

function mkShowcaseChart(canvasId, queryIdx, title) {{
  const ctx = document.getElementById(canvasId).getContext('2d');
  const ds = [];
  for (const mode of ['disk','mem']) {{
    for (const cfg of ['cpu','nopipe','pipe5','pipe10','pipe20']) {{
      const arr = [];
      for (const s of scales) {{
        const key = s+'m_'+mode+'_'+cfg;
        const d = window.__RAW__[key];
        arr.push(d && d.times && d.times[queryIdx] ? +parseFloat(d.times[queryIdx]).toFixed(2) : null);
      }}
      ds.push({{ label: cfg.toUpperCase()+' '+mode, data: arr, borderColor: colors[cfg], borderDash: mode==='mem'?[6,4]:[], fill:false, tension:.25, pointRadius:4 }});
    }}
  }}
  new Chart(ctx, {{ type:'line', data:{{ labels: scales.map(s=>s+'M'), datasets: ds }},
    options:{{ plugins:{{ title:{{ display:true, text: title }} }}, scales:{{ y:{{ title:{{ display:true, text:'Time (s)' }} }} }} }} }});
}}

mkAvgChart('chartAvg');
mkSpeedupChart('chartSpeedup','pipe5');
mkShowcaseChart('chartE12', 11, 'E12 (6 conditions) — time by scale');
mkShowcaseChart('chartS4', 3, 'S4 (3 conditions) — time by scale');
</script>
</body>
</html>'''

with open(r'E:\sqlite-cuda\sqlite\benchmark_report_scale.html', 'w', encoding='utf-8') as f:
    f.write(html)
print('WROTE benchmark_report_scale.html')