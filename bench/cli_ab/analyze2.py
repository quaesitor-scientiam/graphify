import json
import math
import os
import statistics
import sys

# Usage: python -I analyze2.py <results-file> [<results-file> ...] [--keep-first]
# Default file: results.txt. Rounds from several files are pooled per task.
# Each file's sidecar <file>.flags, if present, excludes the rounds it names.

# Two-sided 95% t critical values, by degrees of freedom (n - 1).
T95 = {1: 12.706, 2: 4.303, 3: 3.182, 4: 2.776, 5: 2.571, 6: 2.447, 7: 2.365,
       8: 2.306, 9: 2.262, 10: 2.228, 11: 2.201, 12: 2.179, 13: 2.160, 14: 2.145,
       15: 2.131, 16: 2.120, 17: 2.110, 18: 2.101, 19: 2.093, 20: 2.086}

# Opening line of the wired arm's guidance (run_bench.ps1 $wiredPrompt). A wired
# transcript without it ran a different condition, so its round is excluded.
GUIDANCE = 'prebuilt graphify code graph'

# The first round of each task in each file is a warm-up: the first wired call of a
# run pays the cache write for the whole prefix. --keep-first includes it.
keep_first = '--keep-first' in sys.argv


def stats(path):
    total_in = total_out = total_cache_create = total_cache_read = 0
    turns = 0
    with open(path, encoding='utf-8', errors='replace') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except Exception:
                continue
            msg = obj.get('message', {})
            if not isinstance(msg, dict):
                continue
            usage = msg.get('usage')
            if usage:
                turns += 1
                total_in += usage.get('input_tokens', 0) or 0
                total_out += usage.get('output_tokens', 0) or 0
                total_cache_create += usage.get('cache_creation_input_tokens', 0) or 0
                total_cache_read += usage.get('cache_read_input_tokens', 0) or 0
    unique_input = total_in + total_cache_create
    total_input = unique_input + total_cache_read
    return dict(turns=turns, unique_input=unique_input, total_input=total_input, output=total_out)


def geo_ci(ratios):
    # Geometric mean of the ratios with a 95% CI, from the mean and sd of log ratios.
    logs = [math.log(r) for r in ratios]
    n = len(logs)
    mean = statistics.mean(logs)
    if n < 2:
        return math.exp(mean), None, None
    sd = statistics.stdev(logs)
    half = T95.get(n - 1, 1.96) * sd / math.sqrt(n)
    return math.exp(mean), math.exp(mean - half), math.exp(mean + half)


files = [a for a in sys.argv[1:] if not a.startswith('--')] or ['results.txt']

by_task = {}
for path in files:
    flags = {}
    flags_path = path + '.flags'
    if os.path.exists(flags_path):
        with open(flags_path, encoding='utf-8') as f:
            for line in f:
                line = line.strip()
                if line:
                    task, rnd, msg = line.split('|', 2)
                    flags.setdefault((task, rnd), []).append(msg)

    seen = set()
    with open(path, encoding='utf-8') as f:
        for line in f:
            line = line.strip()
            if not line or line == 'DONE':
                continue
            task, rnd, base_path, wired_path = line.split('|')
            label = f"{os.path.basename(path)} r{rnd}"
            first = task not in seen
            seen.add(task)
            if (task, rnd) in flags:
                print(f"excluded {task} {label}: {'; '.join(flags[(task, rnd)])}")
                continue
            with open(wired_path, encoding='utf-8', errors='replace') as w:
                if GUIDANCE not in w.read():
                    print(f"excluded {task} {label}: wired transcript lacks the guidance prompt (different condition)")
                    continue
            if first and not keep_first:
                print(f"excluded {task} {label}: warm-up round (cold cache); --keep-first to include")
                continue
            b = stats(base_path)
            wd = stats(wired_path)
            by_task.setdefault(task, []).append((label, b, wd))

for task, entries in by_task.items():
    print(f"=== {task}  n={len(entries)} rounds ===")
    ratios_u, ratios_t = [], []
    for label, b, w in entries:
        ru = b['unique_input'] / w['unique_input']
        rt = b['total_input'] / w['total_input']
        ratios_u.append(ru)
        ratios_t.append(rt)
        print(f"  {label}: base uniq={b['unique_input']:>6} total={b['total_input']:>7} turns={b['turns']:>2} | "
              f"wired uniq={w['unique_input']:>6} total={w['total_input']:>7} turns={w['turns']:>2} | "
              f"ratio_uniq={ru:.2f}x ratio_total={rt:.2f}x")
    for label, ratios in (('unique input', ratios_u), ('total input', ratios_t)):
        gm, lo, hi = geo_ci(ratios)
        if lo is None:
            print(f"  {label}: geometric mean {gm:.2f}x (n=1, no interval)")
        else:
            print(f"  {label}: geometric mean {gm:.2f}x, 95% CI {lo:.2f}x to {hi:.2f}x, "
                  f"median {statistics.median(ratios):.2f}x, range {min(ratios):.2f}x to {max(ratios):.2f}x")
    print("  ratio > 1 means the baseline used more tokens than the wired arm")
    print()
