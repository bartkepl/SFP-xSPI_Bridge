# Run VHDL testbenches with GHDL in WSL. Usage: .\run_tests.ps1 [tb_name ...]
# Environment:
#   GOWIN_SIMLIB    Gowin EDA simulation models, e.g. C:\Gowin\IDE\simlib\gw1n (required)
#   GHDL_WSL_DISTRO WSL distribution with GHDL (default: the default distribution)
$distro = if ($env:GHDL_WSL_DISTRO) { @("-d", $env:GHDL_WSL_DISTRO) } else { @() }
$script = (Resolve-Path "$PSScriptRoot\run_tests.sh").Path.Replace('\', '/')
$wslScript = wsl @distro -e wslpath -a $script
$envArgs = @()
if ($env:GOWIN_SIMLIB) {
    $lib = wsl @distro -e wslpath -a $env:GOWIN_SIMLIB.Replace('\', '/')
    $envArgs = @("GOWIN_SIMLIB=$lib")
}
wsl @distro -e env @envArgs bash $wslScript @args
exit $LASTEXITCODE
