#!/usr/bin/env python3
import subprocess, re, json, os, sys, time

BASE = '/root/sqlite'
scales = [50, 100, 250, 500, 750]
modes = ['disk', 'mem']
configs = {
    'cpu': os.path.join(BASE, 'sqlite3_cpu'),
    'nopipe': os.path.join(BASE, 'sqlite3_gpu_nopipe'),
    'pipe5': os.path.join(BASE, 'sqlite3_gpu_pipe_b5m'),
    'pipe10': os.path.join(BASE, 'sqlite3_gpu_pipe_b10m_final'),
    'pipe20': os.path.join(BASE, 'sqlite3_gpu_pipe_b20m'),
    'pipe50': os.path.join(BASE, 'sqlite3_gpu_pipe_b50m'),
}

RESULTS = {}
N_QUERIES = 17
T0 = time.time()
def elapsed(t):
    return f'{time.time()-t:.0f}'

def run_one(binpath, script):
    p = subprocess.run([binpath], stdin=open(script), capture_output=True, text=True)
    out = p.stdout + '\n' + p.stderr
    times = re.findall(r'Run Time: real ([0-9.]+)', out)
    return times, p.returncode, out

start = time.time()
for scale in scales:
    for mode in modes:
        script = os.path.join(BASE, f'q_{scale}m_{mode}.sql')
        if not os.path.exists(script):
            print(f'[WARN] missing {script}', flush=True); continue
        for cfg, binpath in configs.items():
            if not os.path.exists(binpath):
                print(f'[WARN] missing binary {binpath}', flush=True); continue
            key = f'{scale}m_{mode}_{cfg}'
            t0 = time.time()
            try:
                times, rc, out = run_one(binpath, script)
            except Exception as e:
                RESULTS[key] = {'rc': -1, 'error': str(e), 'times': []}
                print(f'[{elapsed(start)}s] {key} ERROR {e}', flush=True)
                with open('results.json', 'w') as f: json.dump(RESULTS, f, indent=2)
                continue
            dt = time.time() - t0
            ok = (rc == 0) and (len(times) >= N_QUERIES)
            print(f'[{elapsed(start)}s wall, {dt:.0f}s] {key} rc={rc} ntimes={len(times)} ok={ok}', flush=True)
            RESULTS[key] = {'rc': rc, 'times': times[:N_QUERIES], 'out': (out if not ok else '')}
            with open('results.json', 'w') as f: json.dump(RESULTS, f, indent=2)
            if not ok and len(out) > 0:
                print('    tail:', out.replace(chr(10),' | ')[-300:], flush=True)

print('ALL DONE', flush=True)
with open('results.json', 'w') as f: json.dump(RESULTS, f, indent=2)
print('results.json written', flush=True)
