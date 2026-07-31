param(
  [string]$Branch,       # branch to switch to (default: current checked-out branch)
  [switch]$Checkout,     # also run git checkout <branch>
  [switch]$Force         # re-extract even if graph already exists
)

$ErrorActionPreference = 'Stop'
$configPath = Join-Path $PSScriptRoot '..\graphify.config.ps1'
if (-not (Test-Path $configPath)) {
  Write-Error "Missing config: $configPath`nCopy graphify.config.ps1.example to graphify.config.ps1 and edit it for your setup."
  exit 1
}
. $configPath

$vlang    = $GraphifyVlangRepo
$graphify = Join-Path $PSScriptRoot 'graphify.exe'
$store    = $GraphifyStore
$claudeJson = "$env:USERPROFILE\.claude.json"

# Resolve branch
if (-not $Branch) {
  $Branch = git -C $vlang branch --show-current 2>$null
  if (-not $Branch) { Write-Error "Could not detect current branch"; exit 1 }
}

# Checkout if requested
if ($Checkout) {
  Write-Host "git checkout $Branch..."
  git -C $vlang checkout $Branch
}

# Sanitize branch name for use as a directory (replace / and \ with -)
$safeBranch = $Branch -replace '[/\\]', '-'

# Graph location: master stays at the original path; branches get their own dir
$graphDir = if ($Branch -in @('master','main')) {
  Join-Path $store 'vlang'
} else {
  Join-Path $store "vlang-$safeBranch"
}
$graphFile = Join-Path $graphDir 'graph.json'

# Extract if missing or forced
if ($Force -or -not (Test-Path $graphFile)) {
  Write-Host "Extracting graph for branch '$Branch' -> $graphDir ..."
  $t = Measure-Command {
    & $graphify extract $vlang --out $graphDir
  }
  Write-Host "Done in $([int]$t.TotalSeconds)s"
} else {
  Write-Host "Graph already exists for '$Branch' (use -Force to re-extract)"
}

# Update ~/.claude.json MCP args to point at this branch's graph
$config = Get-Content $claudeJson | ConvertFrom-Json
$config.mcpServers.graphify.args = @($graphFile)
$config | ConvertTo-Json -Depth 10 | Set-Content $claudeJson
Write-Host "MCP config updated -> $graphFile"
Write-Host ""
Write-Host "Restart Claude Code to load the '$Branch' graph."
