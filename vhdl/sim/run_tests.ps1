# Run VHDL testbenches in WSL (GHDL). Usage: .\run_tests.ps1 [tb_name ...]
$script = (Resolve-Path "$PSScriptRoot\run_tests.sh").Path.Replace('\', '/')
$wslPath = wsl -e wslpath -a $script
wsl -e bash $wslPath @args
exit $LASTEXITCODE
