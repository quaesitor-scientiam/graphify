# Runs the graphify-vs-grep benchmark headless on Windows: the same runs as run.sh.
#
#   pwsh bench/compare/headless/run.ps1 <out-dir> [-NoGrade]
#
# Settings, from the environment, with defaults from graphify.config.json: VLANG,
# GRAPHIFY_MCP (bin\graphify-mcp.exe of this repo), GRAPH, PROJECTS and MODEL, as in
# run.sh. See run.sh for what each run is given and what lands in <out-dir>.
param(
	[Parameter(Mandatory = $true)][string]$Out,
	[switch]$NoGrade
)
$ErrorActionPreference = 'Stop'

$here = $PSScriptRoot
$compare = Split-Path $here -Parent
$repo = (Resolve-Path (Join-Path $compare '..\..')).Path
$config = Join-Path $repo 'graphify.config.json'
$conf = if (Test-Path $config) { Get-Content $config -Raw | ConvertFrom-Json } else { $null }

$VLANG = if ($env:VLANG) { $env:VLANG } elseif ($conf) { $conf.vlang_repo } else { '' }
if (-not $VLANG) { throw 'run.ps1: set VLANG, or vlang_repo in graphify.config.json' }
$store = if ($conf) { $conf.store } else { '' }
$MCP = if ($env:GRAPHIFY_MCP) { $env:GRAPHIFY_MCP } else { Join-Path $repo 'bin\graphify-mcp.exe' }
$GRAPH = if ($env:GRAPH) { $env:GRAPH } else { Join-Path (Join-Path $store (Split-Path $VLANG -Leaf)) 'graph.json' }
$PROJECTS = if ($env:PROJECTS) { $env:PROJECTS } else { $store }
$MODEL = if ($env:MODEL) { $env:MODEL } else { 'claude-opus-5-5' }

New-Item -ItemType Directory -Force $Out | Out-Null
$Out = (Resolve-Path $Out).Path
# the runs see their directory's path; one naming graphify tells the baseline of it
if ($Out -match 'graphify') { throw "run.ps1: pick an <out-dir> whose path doesn't contain 'graphify': $Out" }
if (-not (Get-Command claude -ErrorAction SilentlyContinue)) { throw 'run.ps1: no claude CLI on PATH' }
if (-not (Test-Path $MCP)) { throw "run.ps1: no graphify-mcp at $MCP" }
if (-not (Test-Path (Join-Path $VLANG 'vlib'))) { throw "run.ps1: no vlib in $VLANG" }
if (-not (Test-Path $GRAPH)) { throw "run.ps1: no graph at $GRAPH" }
$commit = (git -C $VLANG rev-parse --short=10 HEAD).Trim()

$cfg = Join-Path $Out 'cfg'
New-Item -ItemType Directory -Force $cfg | Out-Null
'{"mcpServers":{}}' | Set-Content -Encoding utf8 (Join-Path $cfg 'none.json')
@{ mcpServers = @{ graphify = @{ type = 'stdio'; command = $MCP; args = @($GRAPH, '--projects', $PROJECTS); env = @{} } } } |
	ConvertTo-Json -Depth 5 | Set-Content -Encoding utf8 (Join-Path $cfg 'graphify.json')
# the prompts name the V tree with forward slashes, as the answers' paths are written
$vlangSlash = $VLANG -replace '\\', '/'
foreach ($p in 'baseline', 'graphify', 'grade') {
	(Get-Content (Join-Path $here "prompt-$p.md") -Raw).Replace('{{VLANG}}', $vlangSlash).Replace('{{COMMIT}}', $commit) |
		Set-Content -Encoding utf8 (Join-Path $cfg "prompt-$p.md")
}
"run1=graphify run2=baseline run3=baseline run4=graphify vlang=$commit model=$MODEL" |
	Set-Content (Join-Path $Out 'mapping.txt')

$tools = 'Read Grep Glob Bash(rg *) Bash(grep *) Bash(find *) Bash(sed -n *) Bash(cat *) Bash(ls *) Bash(wc *) Bash(head *) Bash(tail *) PowerShell(Get-Content *) PowerShell(Select-String *) PowerShell(Get-ChildItem *)'

$run = {
	param($label, $kind, $Out, $cfg, $compare, $MODEL, $tools)
	$dir = Join-Path $Out $label
	New-Item -ItemType Directory -Force $dir | Out-Null
	Copy-Item (Join-Path $compare 'questions.md') $dir
	Set-Location $dir
	$start = Get-Date
	$prompt = Get-Content (Join-Path $cfg "prompt-$kind.md") -Raw
	if ($kind -eq 'baseline') {
		claude -p --model $MODEL --strict-mcp-config --mcp-config (Join-Path $cfg 'none.json') `
			--setting-sources project,local --allowedTools $tools --output-format stream-json --verbose $prompt `
			2> (Join-Path $Out "$label.err") | Set-Content -Encoding utf8 (Join-Path $Out "$label.jsonl")
	} else {
		claude -p --model $MODEL --strict-mcp-config --mcp-config (Join-Path $cfg 'graphify.json') `
			--allowedTools "$tools mcp__graphify" --output-format stream-json --verbose $prompt `
			2> (Join-Path $Out "$label.err") | Set-Content -Encoding utf8 (Join-Path $Out "$label.jsonl")
	}
	"$label $kind $([int]((Get-Date) - $start).TotalSeconds) s"
}

Write-Host "run.ps1: four runs at vlang $commit, in $Out"
$jobs = @(
	@('run1', 'graphify'), @('run2', 'baseline'), @('run3', 'baseline'), @('run4', 'graphify')
) | ForEach-Object { Start-Job -ScriptBlock $run -ArgumentList $_[0], $_[1], $Out, $cfg, $compare, $MODEL, $tools }
$times = $jobs | Wait-Job | Receive-Job
$times | Set-Content (Join-Path $Out 'times.txt')
$times

# each run's answer, tools and cost, and the baseline's isolation, from its transcript
$kinds = @{ run1 = 'graphify'; run2 = 'baseline'; run3 = 'baseline'; run4 = 'graphify' }
$bad = $false
$lines = foreach ($r in 'run1', 'run2', 'run3', 'run4') {
	$tools_used = @{}; $init = $null; $res = $null
	foreach ($l in Get-Content (Join-Path $Out "$r.jsonl")) {
		try { $d = $l | ConvertFrom-Json } catch { continue }
		if ($d.type -eq 'system' -and $d.subtype -eq 'init') { $init = $d }
		if ($d.type -eq 'assistant') {
			foreach ($c in $d.message.content) { if ($c.type -eq 'tool_use') { $tools_used[$c.name] = 1 + [int]$tools_used[$c.name] } }
		}
		if ($d.type -eq 'result') { $res = $d }
	}
	$mcp = @($init.tools | Where-Object { $_ -like 'mcp__*' })
	$servers = @($init.mcp_servers | ForEach-Object { $_.name })
	if ($kinds[$r] -eq 'baseline' -and ($mcp.Count -or $servers.Count -or ($tools_used.Keys | Where-Object { $_ -like 'mcp__*' }))) { $bad = $true }
	"$($res.result)" | Set-Content -Encoding utf8 (Join-Path $Out "$r.md")
	$calls = ($tools_used.Values | Measure-Object -Sum).Sum
	"$r $($kinds[$r]) turns $($res.num_turns), $([int]($res.duration_ms / 1000)) s, `$$([math]::Round($res.total_cost_usd, 2)), $calls tool calls; MCP servers $($servers -join ',' ), mcp__ tools $($mcp.Count)"
}
$lines | Set-Content (Join-Path $Out 'runs.txt')
$lines
if ($bad) { throw 'run.ps1: a baseline run saw graphify; its results are not a baseline' }

python (Join-Path $compare 'usage.py') "run1=$Out\run1.jsonl" "run2=$Out\run2.jsonl" "run3=$Out\run3.jsonl" "run4=$Out\run4.jsonl" |
	Tee-Object (Join-Path $Out 'usage.txt')

if ($NoGrade) { exit 0 }
# the grader sees the four answers by label only, and checks them with grep at the source
$g = Join-Path $Out 'grader'
New-Item -ItemType Directory -Force $g | Out-Null
Copy-Item (Join-Path $compare 'questions.md'), (Join-Path $compare 'key.md') $g
foreach ($r in 'run1', 'run2', 'run3', 'run4') { Copy-Item (Join-Path $Out "$r.md") $g }
Write-Host 'run.ps1: grading'
Set-Location $g
$prompt = Get-Content (Join-Path $cfg 'prompt-grade.md') -Raw
claude -p --model $MODEL --strict-mcp-config --mcp-config (Join-Path $cfg 'none.json') `
	--setting-sources project,local --allowedTools "$tools Bash(git -C * log *) Bash(git -C * diff *) Bash(git -C * show *)" `
	--output-format json $prompt 2> (Join-Path $Out 'grade.err') | Set-Content -Encoding utf8 (Join-Path $Out 'grade.json')
(Get-Content (Join-Path $Out 'grade.json') -Raw | ConvertFrom-Json).result | Set-Content -Encoding utf8 (Join-Path $Out 'grade.md')
Write-Host "run.ps1: grade in $Out\grade.md"
