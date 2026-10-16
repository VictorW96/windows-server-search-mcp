<#
  Windows Server Search MCP server - stdio entry point.
  Usage: powershell.exe -NoProfile -ExecutionPolicy Bypass -File server.ps1
#>
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module ([IO.Path]::Combine($here, 'WindowsServerSearch.psm1')) -Force -DisableNameChecking

$versionFile = [IO.Path]::Combine($here, 'VERSION')
if (Test-Path -LiteralPath $versionFile) { Set-WssVersion ((Get-Content -LiteralPath $versionFile -Raw).Trim()) }

# Before any COM use: hosts may start this server with a reduced environment.
[void](Restore-WssEnvironment)

if ($env:WSS_FAKE_BACKEND) { Enable-WssFakeBackend -Path $env:WSS_FAKE_BACKEND }

# Create an empty (comments only) %APPDATA%\windows-server-search-mcp\.claude-policy on first start.
[void](Initialize-WssUserPolicy -Config (Get-WssConfig))

Start-WssServer
