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

if ($env:WSS_FAKE_BACKEND) { Enable-WssFakeBackend -Path $env:WSS_FAKE_BACKEND }

Start-WssServer
