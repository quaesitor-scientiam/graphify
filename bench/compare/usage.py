#!/usr/bin/env python3
"""Sums the token usage of benchmark runs from their agents' transcripts.

    python3 bench/compare/usage.py 'graphify A=<transcript>' 'grep A=<transcript>' ...

A transcript is an agent's JSONL output file (a background agent's `.output` under
the session's tasks directory). Each API response is counted once, by its message id.
It prints, per run:

- turns: API responses, the times the whole conversation was sent to the model;
- final context: what the conversation held when the agent stopped;
- cache write / cache read: the input tokens written to and read from the prompt cache
  over all turns, the bulk of what a run reads;
- weighted: cache writes x 1.25 + cache reads x 0.1 + uncached input x 1, the input's
  cost in plain input tokens at the usual relative prices.

Output tokens are left out: the transcripts record only a few hundred a run, too few
to be the real count, and they are small next to the input either way.
"""
import json
import sys


def usage(path):
    by_id = {}
    for line in open(path):
        try:
            d = json.loads(line)
        except ValueError:
            continue
        m = d.get('message')
        if d.get('type') == 'assistant' and isinstance(m, dict) and m.get('usage'):
            by_id[m.get('id')] = m['usage']
    return list(by_id.values())


def main():
    print(f"{'run':12} {'turns':>5} {'final':>8} {'cache w':>8} {'cache r':>10} {'weighted':>9}")
    for arg in sys.argv[1:]:
        name, _, path = arg.partition('=')
        u = usage(path)
        if not u:
            print(f'{name:12} no usage in {path}')
            continue
        fresh = sum(x.get('input_tokens', 0) for x in u)
        write = sum(x.get('cache_creation_input_tokens', 0) for x in u)
        read = sum(x.get('cache_read_input_tokens', 0) for x in u)
        last = u[-1]
        final = sum(last.get(k, 0) for k in ('input_tokens', 'cache_creation_input_tokens',
                                               'cache_read_input_tokens', 'output_tokens'))
        weighted = write * 1.25 + read * 0.1 + fresh
        print(f'{name:12} {len(u):5} {final:8} {write:8} {read:10} {weighted:9.0f}')


if __name__ == '__main__':
    main()
