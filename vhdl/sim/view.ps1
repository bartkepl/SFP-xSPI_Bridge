# Open a testbench waveform in GTKWave. Usage: .\view.ps1 tb_crc32
# GTKWave: environment variable GTKWAVE (path to gtkwave.exe) or gtkwave on PATH.
param([Parameter(Mandatory = $true)][string]$tb)
$gtkwave = if ($env:GTKWAVE) { $env:GTKWAVE } else { "gtkwave" }
if (-not (Get-Command $gtkwave -ErrorAction SilentlyContinue)) {
    Write-Error "GTKWave not found - set GTKWAVE to gtkwave.exe or add it to PATH"; exit 1
}
$wave = "$PSScriptRoot\out\$tb.ghw"
$view = "$PSScriptRoot\waves\$tb.gtkw"
if (-not (Test-Path $wave)) { Write-Error "Missing $wave - run run_tests.ps1 $tb first"; exit 1 }
if (Test-Path $view) { & $gtkwave $wave $view } else { & $gtkwave $wave }
