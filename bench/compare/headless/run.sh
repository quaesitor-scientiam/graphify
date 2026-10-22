#!/usr/bin/env bash
# Runs the graphify-vs-grep benchmark headless, as separate `claude -p` sessions:
# two with graphify, two baseline runs with no graphify at all, then a blind grader.
#
#   bench/compare/headless/run.sh <out-dir> [--no-grade]
#
# Settings, from the environment, with defaults from graphify.config.json (as the
# update script reads it):
#   VLANG          the V tree the questions are about (default: vlang_repo)
#   GRAPHIFY_MCP   the graphify-mcp binary (default: bin/graphify-mcp of this repo)
#   GRAPH          the vlang graph it serves (default: <store>/<vlang's dir name>/graph.json)
#   PROJECTS       its --projects directory (default: store)
#   MODEL          the model every run uses (default: claude-opus-5-5)
#
# A baseline run has no MCP server (--strict-mcp-config with none) and none of the
# user's settings (--setting-sources project,local, from a directory of its own), so
# neither a graphify hook nor ~/.claude/CLAUDE.md reaches it. A graphify run has the
# graphify server and the user's setup, as a normal session has. The script checks
# each run's own start record for that, and fails if a baseline run saw an MCP server.
#
# Runs 1 and 4 use graphify, 2 and 3 are the baseline (mapping.txt); the grader is
# told neither. Everything lands in <out-dir>: each run's transcript (.jsonl) and
# answer (.md), times.txt, runs.txt, usage.txt and grade.md.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
compare="$(dirname "$here")"
repo="$(cd "$compare/../.." && pwd)"
out="${1:?usage: run.sh <out-dir> [--no-grade]}"
grade=1
[[ "${2:-}" == "--no-grade" ]] && grade=0

config_value() {
	[[ -f "$repo/graphify.config.json" ]] || return 0
	python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2],''))" "$repo/graphify.config.json" "$1"
}
VLANG="${VLANG:-$(config_value vlang_repo)}"
STORE="$(config_value store)"
[[ -n "$VLANG" ]] || { echo "run.sh: set VLANG, or vlang_repo in graphify.config.json" >&2; exit 2; }
GRAPHIFY_MCP="${GRAPHIFY_MCP:-$repo/bin/graphify-mcp}"
GRAPH="${GRAPH:-$STORE/$(basename "$VLANG")/graph.json}"
PROJECTS="${PROJECTS:-$STORE}"
MODEL="${MODEL:-claude-opus-5-5}"

mkdir -p "$out"
out="$(cd "$out" && pwd)"
# the runs see their directory's path; one naming graphify tells the baseline of it
case "$out" in *graphify*) echo "run.sh: pick an <out-dir> whose path doesn't contain 'graphify': $out" >&2; exit 2 ;; esac
command -v claude >/dev/null || { echo "run.sh: no claude CLI on PATH" >&2; exit 2; }
[[ -x "$GRAPHIFY_MCP" ]] || { echo "run.sh: no graphify-mcp at $GRAPHIFY_MCP" >&2; exit 2; }
[[ -d "$VLANG/vlib" ]] || { echo "run.sh: no vlib in $VLANG" >&2; exit 2; }
[[ -f "$GRAPH" ]] || { echo "run.sh: no graph at $GRAPH" >&2; exit 2; }
commit="$(git -C "$VLANG" rev-parse --short=10 HEAD)"

cfg="$out/cfg"
mkdir -p "$cfg"
echo '{"mcpServers":{}}' > "$cfg/none.json"
python3 - "$cfg/graphify.json" "$GRAPHIFY_MCP" "$GRAPH" "$PROJECTS" <<'EOF'
import json, sys
path, exe, graph, projects = sys.argv[1:]
json.dump({'mcpServers': {'graphify': {'type': 'stdio', 'command': exe,
           'args': [graph, '--projects', projects], 'env': {}}}}, open(path, 'w'))
EOF
for p in baseline graphify grade; do
	sed -e "s|{{VLANG}}|$VLANG|g" -e "s|{{COMMIT}}|$commit|g" "$here/prompt-$p.md" > "$cfg/prompt-$p.md"
done
echo "run1=graphify run2=baseline run3=baseline run4=graphify vlang=$commit model=$MODEL" > "$out/mapping.txt"

tools="Read Grep Glob Bash(rg *) Bash(grep *) Bash(find *) Bash(sed -n *) Bash(cat *) Bash(ls *) Bash(wc *) Bash(head *) Bash(tail *)"

run() {
	local label=$1 kind=$2 start
	mkdir -p "$out/$label"
	cp "$compare/questions.md" "$out/$label/questions.md"
	start=$(date +%s)
	if [[ $kind == baseline ]]; then
		(cd "$out/$label" && claude -p --model "$MODEL" --strict-mcp-config --mcp-config "$cfg/none.json" \
			--setting-sources project,local --allowedTools "$tools" --output-format stream-json --verbose \
			"$(cat "$cfg/prompt-baseline.md")" > "$out/$label.jsonl" 2> "$out/$label.err") || true
	else
		(cd "$out/$label" && claude -p --model "$MODEL" --strict-mcp-config --mcp-config "$cfg/graphify.json" \
			--allowedTools "$tools mcp__graphify" --output-format stream-json --verbose \
			"$(cat "$cfg/prompt-graphify.md")" > "$out/$label.jsonl" 2> "$out/$label.err") || true
	fi
	echo "$label $kind $(( $(date +%s) - start )) s" >> "$out/times.txt"
}

echo "run.sh: four runs at vlang $commit, in $out"
: > "$out/times.txt"
run run1 graphify & run run2 baseline & run run3 baseline & run run4 graphify &
wait
cat "$out/times.txt"

# each run's answer, tools and cost, and the baseline's isolation, from its transcript
python3 - "$out" <<'EOF'
import collections, json, os, sys
out = sys.argv[1]
kinds = dict(p.split('=') for p in open(os.path.join(out, 'mapping.txt')).read().split()[:4])
bad = False
with open(os.path.join(out, 'runs.txt'), 'w') as f:
    for run in ('run1', 'run2', 'run3', 'run4'):
        tools, init, res = collections.Counter(), None, None
        for line in open(os.path.join(out, run + '.jsonl')):
            try:
                d = json.loads(line)
            except ValueError:
                continue
            if d.get('type') == 'system' and d.get('subtype') == 'init':
                init = d
            if d.get('type') == 'assistant':
                for c in d['message'].get('content', []):
                    if c.get('type') == 'tool_use':
                        tools[c['name']] += 1
            if d.get('type') == 'result':
                res = d
        mcp = [t for t in (init or {}).get('tools', []) if t.startswith('mcp__')]
        servers = [s.get('name') for s in (init or {}).get('mcp_servers', [])]
        if kinds[run] == 'baseline' and (mcp or servers or any(t.startswith('mcp__') for t in tools)):
            bad = True
        open(os.path.join(out, run + '.md'), 'w').write((res or {}).get('result') or '')
        line = (f"{run} {kinds[run]:9} turns {(res or {}).get('num_turns')}, "
                f"{((res or {}).get('duration_ms') or 0) / 1000:.0f} s, ${(res or {}).get('total_cost_usd') or 0:.2f}, "
                f"{sum(tools.values())} tool calls {dict(tools.most_common())}; "
                f"MCP servers {servers or 'none'}, mcp__ tools {len(mcp)}")
        print(line)
        f.write(line + '\n')
if bad:
    print('run.sh: a baseline run saw graphify; its results are not a baseline', file=sys.stderr)
    sys.exit(1)
EOF

python3 "$compare/usage.py" "run1=$out/run1.jsonl" "run2=$out/run2.jsonl" "run3=$out/run3.jsonl" \
	"run4=$out/run4.jsonl" | tee "$out/usage.txt"

[[ $grade == 1 ]] || exit 0
# the grader sees the four answers by label only, and checks them with grep at the source
g="$out/grader"
mkdir -p "$g"
cp "$compare/questions.md" "$compare/key.md" "$g/"
for r in run1 run2 run3 run4; do cp "$out/$r.md" "$g/$r.md"; done
echo "run.sh: grading"
(cd "$g" && claude -p --model "$MODEL" --strict-mcp-config --mcp-config "$cfg/none.json" \
	--setting-sources project,local --allowedTools "$tools Bash(git -C * log *) Bash(git -C * diff *) Bash(git -C * show *)" \
	--output-format json "$(cat "$cfg/prompt-grade.md")" > "$out/grade.json" 2> "$out/grade.err") || true
python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('result',''))" "$out/grade.json" > "$out/grade.md"
echo "run.sh: grade in $out/grade.md"
