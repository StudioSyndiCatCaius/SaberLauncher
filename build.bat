@echo off
setlocal
cd /d "%~dp0"
if not exist APP mkdir APP
powershell -NoProfile -ExecutionPolicy Bypass -Command "iex ((Get-Content -Raw -LiteralPath '%~f0') -replace '(?s)^.*?#PS1\r?\n','')"
exit /b %ERRORLEVEL%

#PS1
# Progress for `odin build`. The compiler prints nothing until it finishes,
# so the bar is elapsed time against the last successful build (capped at
# 95% until the process exits). Failures dump the compiler output unchanged.
$ErrorActionPreference = 'Stop'
$out = 'APP\Saber.exe'
$estPath = Join-Path $env:TEMP 'SaberLauncher_build_ms.txt'
$est = 50000
if (Test-Path -LiteralPath $estPath) {
    $parsed = 0
    $text = (Get-Content -LiteralPath $estPath -Raw).Trim()
    if ([int]::TryParse($text, [ref]$parsed) -and $parsed -ge 3000 -and $parsed -le 900000) {
        $est = $parsed
    }
}

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = 'odin'
$psi.Arguments = 'build src -out:APP\Saber.exe -subsystem:windows -o:speed -vet-unused-imports -resource:res/saber.rc'
$psi.WorkingDirectory = (Get-Location).Path
$psi.UseShellExecute = $false
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.CreateNoWindow = $true

$p = New-Object System.Diagnostics.Process
$p.StartInfo = $psi
try {
    [void]$p.Start()
} catch {
    Write-Host "odin was not found on PATH."
    exit 1
}
$stdoutTask = $p.StandardOutput.ReadToEndAsync()
$stderrTask = $p.StandardError.ReadToEndAsync()

$interactive = -not [Console]::IsOutputRedirected
function Show-Bar([int]$pct, [TimeSpan]$elapsed) {
    if (-not $interactive) { return }
    $width = 32
    $filled = [Math]::Min($width, [Math]::Max(0, [int]($width * $pct / 100)))
    $bar = ('#' * $filled) + ('-' * ($width - $filled))
    $line = '[{0}] {1,3}%  {2:m\:ss}  {3}' -f $bar, $pct, $elapsed, $out
    try {
        $max = [Math]::Max(8, [Console]::WindowWidth - 1)
        if ($line.Length -gt $max) { $line = $line.Substring(0, $max) }
        else { $line = $line.PadRight($max) }
    } catch {}
    [Console]::Write("`r" + $line)
}

$clock = [Diagnostics.Stopwatch]::StartNew()
try {
    if (-not $interactive) { Write-Host "Building $out ..." }
    while (-not $p.HasExited) {
        $pct = [Math]::Min(95, [int](100.0 * $clock.ElapsedMilliseconds / $est))
        Show-Bar $pct $clock.Elapsed
        if (-not $p.WaitForExit(200)) { continue }
    }
} finally {
    if (-not $p.HasExited) { try { $p.Kill() } catch {} }
}
$p.WaitForExit()
$stdoutTask.Wait()
$stderrTask.Wait()
$combined = ($stdoutTask.Result + $stderrTask.Result).Trim()

if ($p.ExitCode -eq 0) {
    $ms = [Math]::Max(1, [int]$clock.ElapsedMilliseconds)
    $next = $ms
    if (Test-Path -LiteralPath $estPath) { $next = [int](0.35 * $est + 0.65 * $ms) }
    Set-Content -LiteralPath $estPath -Value $next -NoNewline
    Show-Bar 100 $clock.Elapsed
    if ($interactive) { Write-Host '' }
    Write-Host ("Built {0} in {1:n1}s" -f $out, ($ms / 1000.0))
    exit 0
}

if ($interactive) { Write-Host '' }
if ($combined) { Write-Host $combined }
exit $p.ExitCode
