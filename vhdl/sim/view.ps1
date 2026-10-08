# Open a testbench waveform in GTKWave. Usage: .\view.ps1 tb_crc32
param([Parameter(Mandatory = $true)][string]$tb)
$gtkwave = "gtkwave"
$wave = "$PSScriptRoot\out\$tb.ghw"
$view = "$PSScriptRoot\waves\$tb.gtkw"
if (-not (Test-Path $wave)) { Write-Error "Brak $wave - uruchom najpierw run_tests.ps1 $tb"; exit 1 }
if (Test-Path $view) { & $gtkwave $wave $view } else { & $gtkwave $wave }
