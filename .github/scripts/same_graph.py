#!/usr/bin/env python3
"""Fail unless every graph.json given has the same symbols and edges.

Used by CI to check that the V3 extractor builds the same graph of the same
tree on every OS (FUTURE_WORK.md section 8). `root`, the extraction's own
absolute path, is expected to differ and is not compared.
"""
import json
import sys
from collections import Counter


def load(path):
    with open(path, encoding="utf-8") as f:
        g = json.load(f)
    return g["symbols"], g["edges"]


def key(item):
    return json.dumps(item, sort_keys=True)


def main(paths):
    if len(paths) < 2:
        sys.exit("usage: same_graph.py graph.json graph.json [graph.json...]")
    base_syms, base_edges = load(paths[0])
    print(f"{paths[0]}: {len(base_syms)} symbols, {len(base_edges)} edges")
    ok = True
    for path in paths[1:]:
        syms, edges = load(path)
        print(f"{path}: {len(syms)} symbols, {len(edges)} edges")
        for what, a, b in (("symbols", base_syms, syms), ("edges", base_edges, edges)):
            if a == b:
                continue
            ok = False
            ca, cb = Counter(map(key, a)), Counter(map(key, b))
            only_a, only_b = ca - cb, cb - ca
            print(f"  {what} differ from {paths[0]}: "
                  f"{sum(only_a.values())} only there, {sum(only_b.values())} only here")
            for k in list(only_a)[:10]:
                print(f"    - {k}")
            for k in list(only_b)[:10]:
                print(f"    + {k}")
            if not only_a and not only_b:
                print("    same items in a different order")
    if not ok:
        sys.exit(1)
    print("all graphs are the same")


if __name__ == "__main__":
    main(sys.argv[1:])
