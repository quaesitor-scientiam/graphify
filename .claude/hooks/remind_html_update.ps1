$raw = [Console]::In.ReadToEnd()
$data = $raw | ConvertFrom-Json -ErrorAction SilentlyContinue
$file = $data.tool_input.file_path
if ($file -match 'SKILL\.md|detect_.*\.sh') {
    Write-Host "REMINDER: SKILL.md or detector changed — update C:\Users\john3\Documents\code-review-reference.html before continuing (Detectors tab + Miss Corpus table + subtitle date)."
}
