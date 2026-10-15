# Integration tests against a real Windows Search index (Windows only).
# Prerequisite: Setup-WindowsSearch.ps1 has run (creates integration-env.json).
#   Invoke-Pester ./tests/integration -Output Detailed

BeforeDiscovery {
    $script:Skip = -not (Test-Path (Join-Path $PSScriptRoot 'integration-env.json'))
    $script:Hosts = @()
    if (-not $Skip) {
        $script:Hosts += @{ Name = 'Windows PowerShell 5.1'; Exe = (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') }
        $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
        if ($pwsh) { $script:Hosts += @{ Name = 'PowerShell 7'; Exe = $pwsh.Source } }
    }
}

BeforeAll {
    if (-not (Test-Path (Join-Path $PSScriptRoot 'integration-env.json'))) { return }
    $script:Env = Get-Content (Join-Path $PSScriptRoot 'integration-env.json') -Raw | ConvertFrom-Json
    $script:ServerScript = (Resolve-Path (Join-Path $PSScriptRoot '../../server/server.ps1')).Path

    function Invoke-Mcp([string]$Exe, [string[]]$Lines, [hashtable]$ExtraEnv = @{}) {
        $psi = New-Object Diagnostics.ProcessStartInfo
        $psi.FileName = $Exe
        $psi.Arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$ServerScript`""
        $psi.UseShellExecute = $false
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $utf8 = New-Object Text.UTF8Encoding($false)
        $psi.StandardOutputEncoding = $utf8
        $psi.StandardErrorEncoding = $utf8
        foreach ($k in 'WSS_FAKE_BACKEND', 'WSS_SERVERS', 'WSS_EXCLUDE') { $psi.EnvironmentVariables.Remove($k) }
        foreach ($k in $ExtraEnv.Keys) { $psi.EnvironmentVariables[$k] = $ExtraEnv[$k] }
        $p = [Diagnostics.Process]::Start($psi)
        $w = New-Object IO.StreamWriter($p.StandardInput.BaseStream, $utf8)
        $all = @('{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}', '{"jsonrpc":"2.0","method":"notifications/initialized"}') + $Lines
        foreach ($l in $all) { $w.Write($l + "`n") }
        $w.Close()
        $errTask = $p.StandardError.ReadToEndAsync()
        $out = $p.StandardOutput.ReadToEnd()
        if (-not $p.WaitForExit(120000)) { $p.Kill(); throw 'server timeout' }
        $script:LastStderr = $errTask.Result
        Write-Host $script:LastStderr
        $msgs = @($out -split "`n" | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
        return $msgs | Where-Object { $_.id -ne 0 }
    }
    function Get-ToolJson($msg) {
        if ($msg.result.isError) { throw "Tool error: $($msg.result.content[0].text)" }
        return $msg.result.content[0].text | ConvertFrom-Json
    }
    function Call([int]$Id, [string]$Tool, [hashtable]$Arguments) {
        return (@{ jsonrpc = '2.0'; id = $Id; method = 'tools/call'; params = @{ name = $Tool; arguments = $Arguments } } | ConvertTo-Json -Depth 10 -Compress)
    }

}

if ($Hosts.Count -eq 0) { $Hosts = @(@{ Name = 'n/a (no integration-env.json)'; Exe = '' }) }
Describe 'Windows Search integration on <Name>' -Skip:$Skip -ForEach $Hosts {
    BeforeAll {
        # Simulate a Cowork workspace folder inside the user profile, identified by a marker file.
        $script:Marker = '.wss-target-' + [guid]::NewGuid().ToString('N').Substring(0, 12)
        $script:Workspace = Join-Path $env:USERPROFILE ("Documents\Claude\ws-" + [guid]::NewGuid().ToString('N').Substring(0, 6))
        New-Item -ItemType Directory -Path $Workspace -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $Workspace $Marker) -Value ''
        $script:CopyDir = Join-Path $env:TEMP ("wss-copy-" + [guid]::NewGuid().ToString('N').Substring(0, 6))
        $script:Msgs = @(Invoke-Mcp $Exe @(
                (Call 1 'list_servers' @{ check = $true }),
                (Call 2 'search_files' @{ query = $Env.Token }),
                (Call 3 'search_files' @{ query = $Env.Token; match = 'filename' }),
                (Call 4 'search_files' @{ query = $Env.Token; path = "$($Env.Drive)\sub folder" }),
                (Call 5 'search_files' @{ extensions = @('log'); sort = 'modified' }),
                (Call 6 'read_file' @{ path = "$($Env.Drive)\alpha.txt" }),
                (Call 7 'list_directory' @{ path = "$($Env.Drive)\" }),
                (Call 8 'read_file' @{ path = 'C:\Windows\win.ini' }),
                (Call 9 'copy_file' @{ path = "$($Env.Drive)\alpha.txt"; destination_marker = $Marker }),
                (Call 10 'copy_file' @{ paths = @("$($Env.Drive)\alpha.txt", "\\$($Env.Computer)\$($Env.Share)\sub folder\beta notes.txt", "$($Env.Drive)\missing.txt"); destination = $CopyDir; subfolder = 'batch' }),
                (Call 11 'copy_file' @{ path = "$($Env.Drive)\alpha.txt"; destination = "$($Env.Drive)\sub folder" }),
                (Call 12 'copy_file' @{ path = 'C:\Windows\win.ini'; destination = $CopyDir }),
                (Call 13 'search_files' @{ query = $Env.Token; path = "$($Env.Drive)\secret" }),
                (Call 14 'read_file' @{ path = "$($Env.Drive)\secret\plan.txt" }),
                (Call 15 'read_file' @{ path = "$($Env.Drive)\SECRET.\plan.txt" }),
                (Call 16 'read_file' @{ path = "$($Env.Drive)\$(if ($Env.ShortName) { $Env.ShortName } else { 'Confidential Documents' })\doc.txt" }),
                (Call 17 'read_file' @{ path = "$($Env.Drive)\$(if ($Env.Symlink) { $Env.Symlink } else { 'secret' })\plan.txt" }),
                (Call 18 'copy_file' @{ path = "$($Env.Drive)\regblocked.txt"; destination = $CopyDir }),
                (Call 19 'list_directory' @{ path = "$($Env.Drive)\secret" })
            ))
    }

    It 'auto-discovers the mapped drive as a Windows server' {
        $r = Get-ToolJson ($Msgs | Where-Object id -eq 1)
        $srv = @($r.servers | Where-Object { $_.name -ieq $Env.Computer })
        $srv.Count | Should -Be 1 -Because ($r | ConvertTo-Json -Depth 10)
        @($srv[0].sources) | Should -Contain 'mapped-drive'
        $share = @($srv[0].shares | Where-Object { $_.name -ieq $Env.Share })
        @($share[0].drives) | Should -Contain $Env.Drive
        $srv[0].index.status | Should -Be 'ok' -Because $srv[0].index.detail
    }

    It 'finds files by content through the remote index query' {
        $r = Get-ToolJson ($Msgs | Where-Object id -eq 2)
        $names = @($r.results | ForEach-Object { $_.name })
        $names | Should -Contain 'alpha.txt'
        $names | Should -Contain 'beta notes.txt'
        $alpha = $r.results | Where-Object name -eq 'alpha.txt'
        $alpha.drive_path | Should -Be "$($Env.Drive)\alpha.txt"
        $alpha.path | Should -BeLike "\\*\$($Env.Share)\alpha.txt"
        $alpha.size | Should -BeGreaterThan 0
    }

    It 'finds files by name only' {
        $r = Get-ToolJson ($Msgs | Where-Object id -eq 3)
        @($r.results | ForEach-Object { $_.name }) | Should -Be @("$($Env.Token)-name-only.log")
    }

    It 'scopes a search to a sub folder of the drive' {
        $r = Get-ToolJson ($Msgs | Where-Object id -eq 4)
        @($r.results | ForEach-Object { $_.name }) | Should -Be @('beta notes.txt')
    }

    It 'filters by extension without a query' {
        $r = Get-ToolJson ($Msgs | Where-Object id -eq 5)
        @($r.results | ForEach-Object { $_.name }) | Should -Contain "$($Env.Token)-name-only.log"
        @($r.results | Where-Object { $_.name -notlike '*.log' }).Count | Should -Be 0
    }

    It 'reads a file through the mapped drive' {
        $r = Get-ToolJson ($Msgs | Where-Object id -eq 6)
        $r.content | Should -Match $Env.Token
        $r.path | Should -BeLike "\\*\$($Env.Share)\alpha.txt"
    }

    It 'lists a directory' {
        $r = Get-ToolJson ($Msgs | Where-Object id -eq 7)
        @($r.entries | ForEach-Object { $_.name }) | Should -Contain 'sub folder'
        @($r.entries | ForEach-Object { $_.name }) | Should -Contain 'alpha.txt'
    }

    It 'copies a file into the workspace folder found via marker' {
        $r = Get-ToolJson ($Msgs | Where-Object id -eq 9)
        $r.destination | Should -Be $Workspace
        $r.destination_source | Should -Be 'marker'
        $r.copied[0].local_path | Should -Be (Join-Path $Workspace 'alpha.txt')
        Get-Content -LiteralPath (Join-Path $Workspace 'alpha.txt') -Raw | Should -Match $Env.Token
    }

    It 'copies several files, reporting per-file errors' {
        $r = Get-ToolJson ($Msgs | Where-Object id -eq 10)
        # %TEMP% may use 8.3 short names (RUNNER~1); compare the actual folders instead of strings.
        (Get-Item -LiteralPath $r.destination).FullName | Should -Be (Get-Item -LiteralPath (Join-Path $CopyDir 'batch')).FullName
        @($r.copied).Count | Should -Be 2
        Test-Path (Join-Path $CopyDir 'batch\beta notes.txt') | Should -BeTrue
        @($r.errors).Count | Should -Be 1
        $r.errors[0].error | Should -Match 'not found'
    }

    It 'never writes to the server' {
        $m = $Msgs | Where-Object id -eq 11
        $m.result.isError | Should -BeTrue
        $m.result.content[0].text | Should -Match 'network drive'
    }

    It 'refuses to copy local files outside the server shares' {
        ($Msgs | Where-Object id -eq 12).result.isError | Should -BeTrue
    }

    It 'hides blocked files from search and reports how many were hidden' {
        $r = Get-ToolJson ($Msgs | Where-Object id -eq 2)
        $names = @($r.results | ForEach-Object { $_.name })
        foreach ($n in 'plan.txt', 'alpha.hidden.txt', 'regblocked.txt', 'doc.txt') { $names | Should -Not -Contain $n }
        $r.hidden_by_policy | Should -Be 4
        $r.policy_note | Should -Match '^4 matching file'
    }

    It 'reports the active access policy in list_servers' {
        $r = Get-ToolJson ($Msgs | Where-Object id -eq 1)
        $r.access_policy.rule_counts.'group-policy' | Should -Be 1
        $r.access_policy.rule_counts.'share-policy' | Should -Be 3
        @($r.access_policy.policy_files | ForEach-Object { $_.share }) | Should -Contain "\\$($Env.Computer)\$($Env.Share)"
        @($r.access_policy.blocked_shares).Count | Should -Be 0
    }

    It 'refuses to search inside a blocked folder' {
        ($Msgs | Where-Object id -eq 13).result.content[0].text | Should -Match 'blocked by the access policy'
    }

    It 'refuses to read blocked files (direct, trailing dot, 8.3 short name, symlink)' {
        foreach ($id in 14, 15, 16, 17) {
            $m = $Msgs | Where-Object id -eq $id
            $m.result.isError | Should -BeTrue -Because "request $id must be blocked"
            $m.result.content[0].text | Should -Match 'blocked' -Because "request $id"
        }
    }

    It 'exercised the 8.3 and symlink bypass paths on this runner' {
        if (-not $Env.ShortName) { Set-ItResult -Skipped -Because '8.3 short names are disabled on this volume' }
        if (-not $Env.Symlink) { Set-ItResult -Skipped -Because 'symlink could not be created' }
    }

    It 'refuses to copy files blocked by group policy' {
        $m = $Msgs | Where-Object id -eq 18
        $m.result.isError | Should -BeTrue
        $m.result.content[0].text | Should -Match 'group-policy'
    }

    It 'hides blocked entries in listings and refuses to list blocked folders' {
        $r = Get-ToolJson ($Msgs | Where-Object id -eq 7)
        $names = @($r.entries | ForEach-Object { $_.name })
        foreach ($n in 'secret', 'alpha.hidden.txt', 'regblocked.txt', 'Confidential Documents') { $names | Should -Not -Contain $n }
        $r.hidden_by_policy | Should -Be 4
        ($Msgs | Where-Object id -eq 19).result.isError | Should -BeTrue
    }

    It 'refuses to read local files outside the server shares' {
        $m = $Msgs | Where-Object id -eq 8
        $m.result.isError | Should -BeTrue
    }
}
