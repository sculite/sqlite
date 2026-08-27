# Benchmark Results & Test Assets (SQLite GPU Acceleration)

Consolidated from the RTX 4000 Ada benchmark server (`sqlite-gpu`, /root/sqlite)
and local Windows builds.

## Layout

- `queries/` — SQL scripts
  - `insert_*m.sql` — generate the row datasets (50M–750M)
  - `q_*m_disk.sql` / `q_*m_mem.sql` — the 17-query benchmark suites (disk / `:memory:`)
  - `q_*_template.sql` — templates used to generate the per-scale suites
  - `test_*.sql` / `bench*.sql` — earlier single-machine test suites
- `results/` — raw outputs & logs
  - `results.json` — full matrix: 60 runs (5 scales × 2 modes × 6 configs × 17 queries)
  - `matrix_log*.txt` — driver progress logs (`run_matrix.py`)
  - `*_out.txt` — per-config sqlite3 stdout (CPU/non-pipe/pipe at various scales)
  - `ctr_*.txt` — CPU vs GPU byte-for-byte correctness diffs (100M & 750M) — all IDENTICAL
  - `mem_*_out.txt`, `mfull_*_out.txt` — 500M in-memory full 17-query runs
- `reports/`
  - `benchmark_report_500m.html` — 500M: all configs × disk/in-memory × 17 queries
  - `benchmark_report_scale.html` — scale progression 50M→750M with charts
  - `results_raw.json` — same data as `results/results.json` (recopy for edits)
  - `gen_scale_report.py` — regenerates the scale HTML report from `results_raw.json`
- `scripts/`
  - `run_matrix.py` — remote driver that ran the full benchmark matrix

## Configs compared

- `cpu` — plain SQLite (no GPU)
- `nopipe` — GPU, non-pipelined loop, 10M batch
- `pipe5 / pipe10 / pipe20 / pipe50` — GPU pipelined, batch sizes 5M/10M/20M/50M
  (pipe50 OOM'd at every scale — excluded from analyses)

## Key results

- Best config: GPU pipelined, 5M batch. Correct on all 17 queries at all scales.
- Speedup vs CPU grows with scale (e.g. S4 3-cond on-disk: 1.55× at 50M → 2.14× at 750M).
- At 50M GPU barely beats CPU; smaller batches win, 20M+ is slower, 50M OOMs.