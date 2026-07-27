$raw = [Console]::In.ReadToEnd()
$data = $raw | ConvertFrom-Json -ErrorAction SilentlyContinue
$file = $data.tool_input.file_path
if ($file -match 'h2_(mux_conn|conn|server|frame|hpack)\.v$') {
    Write-Host "PHASE R CHECK: If this edit responds to a Codex or external-reviewer finding — STOP and complete Phase R first: (1) record miss, (2) diagnose angle, (3) fix/add detector, (4) reproduce detector on BUGGY commit (must exit 1), (5) confirm detector clears on fixed tree, (6) log in code-review-misses corpus. Only THEN fix the code. Fixing first makes step 4 unverifiable."
}
