# launch.ps1
# Launch AgentTUI in an isolated WezTerm window
# This does NOT affect your existing WezTerm configuration

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigFile = Join-Path $ScriptDir "src\agenttui.lua"

if (-not (Get-Command "wezterm" -ErrorAction SilentlyContinue)) {
    Write-Error "wezterm not found in PATH. Please install WezTerm first."
    exit 1
}

if (-not (Test-Path $ConfigFile)) {
    Write-Error "Config file not found: $ConfigFile"
    exit 1
}

Write-Host "Launching AgentTUI..." -ForegroundColor Cyan
Write-Host "Config: $ConfigFile" -ForegroundColor DarkGray
Write-Host "(Your existing WezTerm config is not affected)" -ForegroundColor DarkGray

wezterm --config-file "$ConfigFile" $args
