# End-to-end test: launches server.ps1 as a child process and speaks MCP over stdio,
# using the fake backend (WSS_FAKE_BACKEND) so it runs on any OS.

BeforeAll {
    $script:ServerScript = (Resolve-Path (Join-Path $PSScriptRoot '../server/server.ps1')).Path
    $script:Tmp = Join-Path ([IO.Path]::GetTempPath()) "wss-e2e-$([guid]::NewGuid())"
    New-Item -ItemType Directory -Path $Tmp | Out-Null
    $script:Fake = Join-Path $Tmp 'fake.json'
    $script:SqlLog = Join-Path $Tmp 'sql.log'
    @{
        mappedDrives = @(@{ drive = 'Z:'; unc = '\\fs01.corp.local\projects' })
        results      = @{ fs01 = @(@{ 'System.ItemUrl' = 'file://fs01/projects/Ünïcode report.docx'; 'System.FileName' = 'Ünïcode report.docx'; 'System.Size' = 42; 'System.Search.Rank' = 1000 }) }
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Fake -Encoding UTF8

    function Invoke-Server([string[]]$Lines) {
        # Prefer the host that runs the tests (powershell.exe on 5.1, pwsh otherwise)
        $exe = (Get-Process -Id $PID).Path
        $psi = New-Object Diagnostics.ProcessStartInfo
        $psi.FileName = $exe
        $psi.Arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$ServerScript`""
        $psi.UseShellExecute = $false
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $utf8 = New-Object Text.UTF8Encoding($false)
        $psi.StandardOutputEncoding = $utf8
        $psi.StandardErrorEncoding = $utf8
        $psi.EnvironmentVariables['WSS_FAKE_BACKEND'] = $Fake
        $psi.EnvironmentVariables['WSS_FAKE_SQL_LOG'] = $SqlLog
        $psi.EnvironmentVariables['WSS_SERVERS'] = ''
        $p = [Diagnostics.Process]::Start($psi)
        $stdin = New-Object IO.StreamWriter($p.StandardInput.BaseStream, $utf8)
        foreach ($l in $Lines) { $stdin.Write($l + "`n") }
        $stdin.Close()
        $errTask = $p.StandardError.ReadToEndAsync()
        $out = $p.StandardOutput.ReadToEnd()
        if (-not $p.WaitForExit(60000)) { $p.Kill(); throw 'server did not exit' }
        $script:LastStderr = $errTask.Result
        return @($out -split "`n" | Where-Object { $_.Trim() })
    }
}

AfterAll { Remove-Item $Tmp -Recurse -Force -ErrorAction SilentlyContinue }

Describe 'stdio server (fake backend)' {
    It 'runs a full MCP session and writes only JSON-RPC to stdout' {
        $lines = Invoke-Server @(
            '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"pester","version":"1"}}}',
            '{"jsonrpc":"2.0","method":"notifications/initialized"}',
            '{"jsonrpc":"2.0","id":2,"method":"tools/list"}',
            '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_servers","arguments":{}}}',
            '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"search_files","arguments":{"query":"report","extensions":["docx"]}}}'
        )
        $lines.Count | Should -Be 4 -Because "stderr was: $LastStderr"
        $msgs = $lines | ForEach-Object { $_ | ConvertFrom-Json }
        $msgs[0].result.serverInfo.name | Should -Be 'windows-server-search'
        $msgs[1].result.tools.Count | Should -Be 5
        ($msgs[2].result.content[0].text | ConvertFrom-Json).servers[0].query_machine | Should -Be 'fs01'
        $search = $msgs[3].result.content[0].text | ConvertFrom-Json
        $search.results[0].name | Should -Be 'Ünïcode report.docx'
        $search.results[0].drive_path | Should -Be 'Z:\Ünïcode report.docx'
        Get-Content -LiteralPath $SqlLog -Raw | Should -Match "FROM fs01\.SystemIndex WHERE SCOPE='file://fs01/projects'"
    }
}
