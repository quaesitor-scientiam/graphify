# CLI A/B benchmark: graphify available vs not

Live A/B on the same task and corpus. The baseline arm has no graph; the wired arm
gets the graphify CLI and a short guidance prompt. Both arms run `claude --safe-mode`
on Sonnet, so the only intended difference is whether the graph is available.

- `run_bench.ps1` runs the tasks (`nav`, `deep`, `summarize`, `resolve`) for a number
  of rounds, one results file per run, with a `.flags` sidecar for validity problems.
- `analyze2.py` pools one or more results files and reports, per task, the geometric
  mean of baseline ÷ wired token counts with a 95% CI. A ratio above 1 means the
  baseline used more tokens.

## Paths

The scripts were run from a local working copy and still contain its paths:
`S:\gf-bench2` (both arms and results), `S:/vProjects/graphify/bin/graphify.exe`
(the CLI) and `S:/gf-bench2/wired/graphify-out/graph.json` (the graph). Change them
before running elsewhere. The raw transcripts and the per-run results files are not
committed; they hold local paths.

## Method

- Corpus: `vlib/v`, byte-identical in both arms, with `.claude/AGENTS.md` excluded.
- Warm-up: the first round of each task in each results file is excluded, because
  the first wired call pays the cache write for the whole prefix.
- Condition check: a round is excluded if its wired transcript lacks the guidance
  prompt. This excluded the first (three-round) resolve run, whose wired transcripts
  used graphify without that prompt.
- Validity flags: a round with a flag (baseline mentions graphify, wired never uses
  it, or wired has failed invocations) is excluded and listed.

## Results

Ratios are baseline ÷ wired. Warm-up rounds excluded. Intervals are 95% t-intervals on
the log ratios, so they assume rounds are independent. Rounds within a run may share
cache state, so the intervals may be optimistic.

| Task | Rounds | Total input (geo. mean, 95% CI) | Unique input (geo. mean, 95% CI) |
|---|---|---|---|
| `resolve`, two runs pooled | 10 | 2.02x (1.62 to 2.52) | 1.72x (1.26 to 2.36) |
| `nav` | 5 | 2.80x (1.44 to 5.46) | 2.89x (1.76 to 4.76) |
| `deep` | 5 | 1.81x (1.20 to 2.72) | 1.27x (0.73 to 2.21) |
| `summarize` | 5 | 2.03x (1.49 to 2.77) | 1.22x (0.86 to 1.72) |

The two `resolve` runs disagree more than their intervals suggest: one alone gives
1.83x total (1.19 to 2.81) and the other 2.22x (1.59 to 3.11).

## Caveats

- One model (Sonnet), one corpus, and four tasks written for this corpus. None of
  these results cover other models, corpora or prompts.
- Five or ten rounds per task. Round-to-round spread is wide; total-input ratios for `nav`
  ran from 1.18x (round 2) to 4.23x (round 5).
- "Total input" counts cache reads and is a cost proxy, not a billing figure.
- The wired arm's guidance prompt is part of the treatment. A different prompt could
  change the result.

## Rerun

```
pwsh bench/cli_ab/run_bench.ps1 -Tasks nav,deep,summarize,resolve -Rounds 6 -Out <new-results-file>
python bench/cli_ab/analyze2.py <results-file> [<results-file> ...]
```

`-Out` must name a file that does not exist yet. Pass `--keep-first` to the analyzer
to include warm-up rounds.
