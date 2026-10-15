# Unit tests - run anywhere PowerShell runs (Windows PowerShell 5.1, pwsh on Linux/macOS).
#   Invoke-Pester ./tests -Output Detailed

BeforeAll {
    $env:WSS_LOG_LEVEL = 'silent'
    Import-Module (Join-Path $PSScriptRoot '../server/WindowsServerSearch.psm1') -Force -DisableNameChecking
    $script:Mod = Get-Module WindowsServerSearch

    function Set-TestBackend {
        param($Drives = @(), $Shares = @{}, $Rows = @{}, $Errors = @{})
        & $script:Mod {
            param($Drives, $Shares, $Rows, $Errors)
            $script:TestDrives = $Drives; $script:TestShares = $Shares; $script:TestRows = $Rows; $script:TestErrors = $Errors
            $script:TestSql = New-Object System.Collections.ArrayList
            $script:DriveProvider = { $script:TestDrives }
            $script:ShareProvider = { param($h) foreach ($k in $script:TestShares.Keys) { if ($k -ieq $h) { return $script:TestShares[$k] } }; @() }
            $script:QueryExecutor = {
                param($m, $sql, $t)
                [void]$script:TestSql.Add(@{ Machine = $m; Sql = $sql })
                foreach ($k in $script:TestErrors.Keys) { if ($k -ieq $m) { throw $script:TestErrors[$k] } }
                foreach ($k in $script:TestRows.Keys) { if ($k -ieq $m) { return $script:TestRows[$k] } }
                @()
            }
        } $Drives $Shares $Rows $Errors
    }
    function Get-TestSql { & $script:Mod { @($script:TestSql) } }
    function New-TestConfig {
        param($Servers = @(), $AutoDiscover = $true, $Exclude = @(), $MaxResults = 50)
        @{ Servers = @($Servers); AutoDiscover = $AutoDiscover; Exclude = @($Exclude); MaxResults = $MaxResults; QueryTimeout = 5; UseNetBios = $true }
    }
}

AfterAll {
    Remove-Module WindowsServerSearch -Force -ErrorAction SilentlyContinue
}

Describe 'ConvertFrom-WssUncPath' {
    It 'parses <path>' -TestCases @(
        @{ path = '\\fs01\share\a\b.txt'; h = 'fs01'; s = 'share'; r = 'a\b.txt' }
        @{ path = '\\fs01\share'; h = 'fs01'; s = 'share'; r = '' }
        @{ path = '\\fs01\share\'; h = 'fs01'; s = 'share'; r = '' }
        @{ path = '\\fs01'; h = 'fs01'; s = $null; r = '' }
        @{ path = '//fs01/share/x'; h = 'fs01'; s = 'share'; r = 'x' }
        @{ path = 'file://fs01/share/My%20Docs/x.txt'; h = 'fs01'; s = 'share'; r = 'My Docs\x.txt' }
        @{ path = 'file:///fs01/share/x'; h = 'fs01'; s = 'share'; r = 'x' }
    ) {
        $u = ConvertFrom-WssUncPath $path
        $u.Host | Should -Be $h
        $u.Share | Should -Be $s
        $u.Rest | Should -Be $r
    }
    It 'rejects non-UNC paths' {
        ConvertFrom-WssUncPath 'C:\temp' | Should -BeNullOrEmpty
        ConvertFrom-WssUncPath '\\?\C:\temp' | Should -BeNullOrEmpty
        ConvertFrom-WssUncPath '' | Should -BeNullOrEmpty
    }
}

Describe 'Get-WssQueryMachine' {
    It 'uses the NetBIOS name for FQDNs' { Get-WssQueryMachine 'fs01.corp.example.com' | Should -Be 'fs01' }
    It 'keeps IP addresses' { Get-WssQueryMachine '10.0.0.5' | Should -Be '10.0.0.5' }
    It 'keeps FQDN when NetBIOS is disabled' { Get-WssQueryMachine 'fs01.corp' $false | Should -Be 'fs01.corp' }
}

Describe 'Get-WssConfig' {
    BeforeEach {
        foreach ($n in 'WSS_SERVERS', 'WSS_AUTO_DISCOVER', 'WSS_EXCLUDE', 'WSS_MAX_RESULTS', 'WSS_QUERY_TIMEOUT', 'WSS_USE_NETBIOS') { Remove-Item "env:$n" -ErrorAction SilentlyContinue }
        $env:WSS_CONFIG_FILE = Join-Path ([IO.Path]::GetTempPath()) "wss-test-$([guid]::NewGuid()).json"
    }
    AfterEach {
        Remove-Item $env:WSS_CONFIG_FILE -ErrorAction SilentlyContinue
        foreach ($n in 'WSS_SERVERS', 'WSS_AUTO_DISCOVER', 'WSS_EXCLUDE', 'WSS_MAX_RESULTS', 'WSS_CONFIG_FILE') { Remove-Item "env:$n" -ErrorAction SilentlyContinue }
    }
    It 'has sensible defaults' {
        $c = Get-WssConfig
        $c.Servers.Count | Should -Be 0
        $c.AutoDiscover | Should -BeTrue
        $c.MaxResults | Should -Be 50
        $c.UseNetBios | Should -BeTrue
    }
    It 'reads environment variables (as set by plugin userConfig)' {
        $env:WSS_SERVERS = '\\fs01\a; \\fs02 ,\\fs03\b'
        $env:WSS_AUTO_DISCOVER = 'false'
        $env:WSS_MAX_RESULTS = '9999'
        $c = Get-WssConfig
        $c.Servers | Should -Be @('\\fs01\a', '\\fs02', '\\fs03\b')
        $c.AutoDiscover | Should -BeFalse
        $c.MaxResults | Should -Be 500
    }
    It 'treats empty plugin options as defaults' {
        $env:WSS_SERVERS = ''
        $env:WSS_MAX_RESULTS = ''
        $env:WSS_AUTO_DISCOVER = ''
        $c = Get-WssConfig
        $c.Servers.Count | Should -Be 0
        $c.MaxResults | Should -Be 50
        $c.AutoDiscover | Should -BeTrue
    }
    It 'ignores unresolved plugin placeholders' {
        $env:WSS_SERVERS = '${user_config.servers}'
        $env:WSS_MAX_RESULTS = '${user_config.max_results}'
        $c = Get-WssConfig
        $c.Servers.Count | Should -Be 0
        $c.MaxResults | Should -Be 50
    }
    It 'reads the JSON config file, env wins' {
        '{"servers":["\\\\fs09\\x"],"maxResults":7,"autoDiscover":false}' | Set-Content -LiteralPath $env:WSS_CONFIG_FILE
        $c = Get-WssConfig
        $c.Servers | Should -Be @('\\fs09\x')
        $c.MaxResults | Should -Be 7
        $c.AutoDiscover | Should -BeFalse
        $env:WSS_MAX_RESULTS = '3'
        (Get-WssConfig).MaxResults | Should -Be 3
    }
}

Describe 'ConvertFrom-WssNetView' {
    It 'parses English output' {
        $lines = @(
            'Shared resources at \\FS01', '', '', '',
            'Share name  Type  Used as  Comment', '',
            '-------------------------------------------------------------------------------',
            'Projects    Disk           Project files',
            'HR Data     Disk  Z:',
            'Users       Disk',
            'The command completed successfully.'
        )
        ConvertFrom-WssNetView $lines | Should -Be @('Projects', 'HR Data', 'Users')
    }
    It 'parses German output' {
        $lines = @(
            'Freigegebene Ressourcen auf \\FS01', '',
            'Freigabename  Typ          Verwendet als  Kommentar', '',
            '-------------------------------------------------------------------------------',
            'Daten         Platte',
            'Scans         Platte       Y:',
            'Der Befehl wurde erfolgreich ausgeführt.'
        )
        ConvertFrom-WssNetView $lines | Should -Be @('Daten', 'Scans')
    }
}

Describe 'Get-WssTargets' {
    It 'auto-discovers servers from mapped drives and groups shares per server' {
        Set-TestBackend -Drives @(
            @{ Drive = 'Z:'; Unc = '\\FS01\Projects' },
            @{ Drive = 'Y:'; Unc = '\\fs01\HR' },
            @{ Drive = 'X:'; Unc = '\\fs02.corp.local\data' },
            @{ Drive = 'W:'; Unc = '\\fs01\projects' }
        )
        $t = @(Get-WssTargets -Config (New-TestConfig))
        $t.Count | Should -Be 2
        $t[0].Name | Should -Be 'FS01'
        $t[0].Shares.Count | Should -Be 2
        @($t[0].Shares[0].Drives) | Should -Be @('Z:', 'W:')
        $t[1].Machine | Should -Be 'fs02'
        @($t[1].Sources) | Should -Be @('mapped-drive')
    }
    It 'ignores mapped drives when auto-discovery is off' {
        Set-TestBackend -Drives @(@{ Drive = 'Z:'; Unc = '\\fs01\p' })
        @(Get-WssTargets -Config (New-TestConfig -AutoDiscover $false)).Count | Should -Be 0
    }
    It 'merges configured servers and enumerates shares for bare server names' {
        Set-TestBackend -Drives @(@{ Drive = 'Z:'; Unc = '\\fs01\p' }) -Shares @{ fs03 = @('a', 'b') }
        $t = @(Get-WssTargets -Config (New-TestConfig -Servers @('\\fs01\q', 'fs03', '\\fs04\x\sub dir')))
        $t.Count | Should -Be 3
        @($t[0].Sources) | Should -Be @('mapped-drive', 'config')
        @($t[0].Shares | ForEach-Object { $_.Unc }) | Should -Be @('\\fs01\p', '\\fs01\q')
        @($t[1].Shares | ForEach-Object { $_.Unc }) | Should -Be @('\\fs03\a', '\\fs03\b')
        @($t[2].Shares | ForEach-Object { $_.Unc }) | Should -Contain '\\fs04\x\sub dir'
    }
    It 'honours exclusions by server and by share' {
        Set-TestBackend -Drives @(@{ Drive = 'Z:'; Unc = '\\fs01\p' }, @{ Drive = 'Y:'; Unc = '\\fs01\q' }, @{ Drive = 'X:'; Unc = '\\fs02\r' })
        $t = @(Get-WssTargets -Config (New-TestConfig -Exclude @('fs02', '\\fs01\q')))
        $t.Count | Should -Be 1
        @($t[0].Shares | ForEach-Object { $_.Unc }) | Should -Be @('\\fs01\p')
    }
}

Describe 'Get-WssQueryTerms' {
    It 'tokenises words, phrases, exclusions and OR' {
        $t = @(Get-WssQueryTerms 'budget "project alpha" -draft invoice OR receipt')
        $t.Count | Should -Be 5
        $t[1].Phrase | Should -BeTrue
        $t[1].Text | Should -Be 'project alpha'
        $t[2].Exclude | Should -BeTrue
        $t[4].Or | Should -BeTrue
    }
    It 'strips characters that would break CONTAINS' {
        $t = @(Get-WssQueryTerms 'a*b (c)')
        $t[0].Text | Should -Be 'a b'
        $t[1].Text | Should -Be 'c'
    }
}

Describe 'New-WssSearchSql' {
    It 'builds a remote query scoped to shares' {
        $sql = New-WssSearchSql -Machine 'fs01' -Scopes @('\\fs01\p', '\\fs01\q\sub dir') -Query 'report' -Top 10
        $sql | Should -Match '^SELECT TOP 10 System\.ItemUrl, '
        $sql | Should -Match 'FROM fs01\.SystemIndex WHERE'
        $sql | Should -Match "\(SCOPE='file://fs01/p' OR SCOPE='file://fs01/q/sub dir'\)"
        $sql | Should -Match ([regex]::Escape("(CONTAINS(*, '`"report*`"') OR System.FileName LIKE '%report%')"))
        $sql | Should -Match 'ORDER BY System\.Search\.Rank DESC$'
    }
    It 'escapes single quotes (no SQL injection)' {
        $sql = New-WssSearchSql -Machine 'fs01' -Query "o'brien') OR 1=1 --" -Match filename
        $sql | Should -Match ([regex]::Escape("System.FileName LIKE '%o''brien''%'"))
        $sql | Should -Not -Match "[^']'brien"
        $sql | Should -Not -Match '%-%'
    }
    It 'escapes LIKE wildcards in file name matching' {
        New-WssSearchSql -Machine 'fs01' -Query '100%_done' -Match filename | Should -Match ([regex]::Escape("LIKE '%100[%][_]done%'"))
    }
    It 'supports filters' {
        $sql = New-WssSearchSql -Machine 'fs01' -Extensions @('pdf', '.DOCX') -Kind 'Document' -Author 'Alice' -ModifiedAfter '2024-01-01' -ModifiedBefore '2024-02-01T12:30:00Z' -Sort modified
        $sql | Should -Match ([regex]::Escape("(System.FileExtension = '.pdf' OR System.FileExtension = '.docx')"))
        $sql | Should -Match ([regex]::Escape("System.Kind = 'document'"))
        $sql | Should -Match ([regex]::Escape("System.Author = 'Alice'"))
        $sql | Should -Match ([regex]::Escape("System.DateModified >= '2024-01-01 00:00:00'"))
        $sql | Should -Match ([regex]::Escape("System.DateModified <= '2024-02-01 12:30:00'"))
        $sql | Should -Match 'ORDER BY System\.DateModified DESC$'
    }
    It 'contents/filename match modes and exclusions' {
        New-WssSearchSql -Machine 'm' -Query 'a' -Match contents | Should -Not -Match 'LIKE'
        New-WssSearchSql -Machine 'm' -Query 'a' -Match filename | Should -Not -Match 'CONTAINS'
        New-WssSearchSql -Machine 'm' -Query 'a -b' -Match contents | Should -Match ([regex]::Escape("CONTAINS(*, '`"a*`"') AND NOT CONTAINS(*, '`"b*`"')"))
        New-WssSearchSql -Machine 'm' -Query 'a OR b' -Match contents | Should -Match ([regex]::Escape("(CONTAINS(*, '`"a*`"') OR CONTAINS(*, '`"b*`"'))"))
    }
    It 'rejects invalid input' {
        { New-WssSearchSql -Machine 'fs01; DROP' -Query 'x' } | Should -Throw
        { New-WssSearchSql -Machine 'fs01' -Extensions @("pdf'") } | Should -Throw
        { New-WssSearchSql -Machine 'fs01' -Kind "doc'x" } | Should -Throw
        { New-WssSearchSql -Machine 'fs01' -ModifiedAfter 'yesterday-ish' } | Should -Throw '*modified_after*'
    }
    It 'excludes folders by default' {
        New-WssSearchSql -Machine 'm' -Query 'x' | Should -Match "System\.ItemType <> 'Directory'"
        New-WssSearchSql -Machine 'm' -Query 'x' -IncludeFolders $true | Should -Not -Match 'Directory'
    }
}

Describe 'Search-Wss' {
    BeforeEach {
        Set-TestBackend -Drives @(
            @{ Drive = 'Z:'; Unc = '\\fs01.corp\projects' },
            @{ Drive = 'Y:'; Unc = '\\fs02\hr' }
        ) -Rows @{
            fs01 = @(
                @{ 'System.ItemUrl' = 'file://fs01/projects/a/Plan.docx'; 'System.FileName' = 'Plan.docx'; 'System.Size' = 10; 'System.DateModified' = [datetime]'2024-03-01'; 'System.Search.Rank' = 500; 'System.Author' = [object[]]@('Alice', 'Bob') }
            )
            fs02 = @(
                @{ 'System.ItemUrl' = 'file://fs02/hr/Plan%20HR.pdf'; 'System.FileName' = 'Plan HR.pdf'; 'System.Size' = 20; 'System.DateModified' = [datetime]'2024-04-01'; 'System.Search.Rank' = 900 }
            )
        }
    }
    It 'queries all servers and merges by rank' {
        $r = Search-Wss -Arguments @{ query = 'plan' } -Config (New-TestConfig)
        $r.result_count | Should -Be 2
        $r.results[0].name | Should -Be 'Plan HR.pdf'
        $r.results[0].path | Should -Be '\\fs02\hr\Plan HR.pdf'
        $r.results[0].drive_path | Should -Be 'Y:\Plan HR.pdf'
        $r.results[1].drive_path | Should -Be 'Z:\a\Plan.docx'
        $r.results[1].author | Should -Be @('Alice', 'Bob')
        $r.results[1].modified | Should -Match '^2024-0[23]-'
        @(Get-TestSql).Count | Should -Be 2
        (Get-TestSql)[0].Machine | Should -Be 'fs01'
    }
    It 'filters by server' {
        $r = Search-Wss -Arguments @{ query = 'plan'; server = 'fs02' } -Config (New-TestConfig)
        $r.servers_queried | Should -Be @('fs02')
    }
    It 'scopes to a mapped drive folder' {
        $null = Search-Wss -Arguments @{ query = 'plan'; path = 'Z:\a\b' } -Config (New-TestConfig)
        $sql = @(Get-TestSql)
        $sql.Count | Should -Be 1
        $sql[0].Sql | Should -Match "SCOPE='file://fs01/projects/a/b'"
    }
    It 'reports partial failures and keeps other results' {
        Set-TestBackend -Drives @(@{ Drive = 'Z:'; Unc = '\\fs01\p' }, @{ Drive = 'Y:'; Unc = '\\fs02\hr' }) -Rows @{ fs01 = @(@{ 'System.ItemUrl' = 'file://fs01/p/x.txt'; 'System.FileName' = 'x.txt' }) } -Errors @{ fs02 = 'boom 0x80040E37' }
        $r = Search-Wss -Arguments @{ query = 'x' } -Config (New-TestConfig)
        $r.result_count | Should -Be 1
        $r.errors[0].server | Should -Be 'fs02'
        $r.errors[0].error | Should -Match 'Windows Search Service'
    }
    It 'throws when every server fails' {
        Set-TestBackend -Drives @(@{ Drive = 'Z:'; Unc = '\\fs01\p' }) -Errors @{ fs01 = 'nope' }
        { Search-Wss -Arguments @{ query = 'x' } -Config (New-TestConfig) } | Should -Throw '*All index queries failed*'
    }
    It 'throws a helpful error when nothing is configured' {
        Set-TestBackend
        { Search-Wss -Arguments @{ query = 'x' } -Config (New-TestConfig) } | Should -Throw '*No Windows servers*'
    }
    It 'requires a query or filter' {
        { Search-Wss -Arguments @{} -Config (New-TestConfig) } | Should -Throw '*query or at least one filter*'
    }
    It 'validates enum arguments' {
        { Search-Wss -Arguments @{ query = 'x'; match = 'bogus' } -Config (New-TestConfig) } | Should -Throw '*Invalid match*'
    }
    It 'limits results' {
        $r = Search-Wss -Arguments @{ query = 'plan'; max_results = 1 } -Config (New-TestConfig)
        $r.result_count | Should -Be 1
        (Get-TestSql)[0].Sql | Should -Match '^SELECT TOP 1 '
    }
}

Describe 'Resolve-WssPath' {
    BeforeAll {
        Set-TestBackend -Drives @(@{ Drive = 'Z:'; Unc = '\\fs01.corp\projects' })
        $script:T = @(Get-WssTargets -Config (New-TestConfig))
    }
    It 'maps drive paths to UNC' { Resolve-WssPath 'z:\a\b.txt' $T | Should -Be '\\fs01.corp\projects\a\b.txt' }
    It 'accepts NetBIOS and FQDN UNC paths' {
        Resolve-WssPath '\\fs01\projects\x' $T | Should -Be '\\fs01\projects\x'
        Resolve-WssPath '\\FS01.corp\Projects\x' $T | Should -Be '\\FS01.corp\Projects\x'
    }
    It 'blocks traversal outside the share' {
        { Resolve-WssPath 'Z:\..\..\other\x' $T } | Should -Not -Throw
        Resolve-WssPath 'Z:\..\..\x' $T | Should -Be '\\fs01.corp\projects\x'
        { Resolve-WssPath '\\fs01\otherShare\x' $T } | Should -Throw '*outside*'
        { Resolve-WssPath '\\evil\projects\x' $T } | Should -Throw '*outside*'
        { Resolve-WssPath 'C:\Windows\win.ini' $T } | Should -Throw '*not a mapped drive*'
    }
}

Describe 'Get-WssDocumentText' {
    BeforeAll {
        $script:Dir = Join-Path ([IO.Path]::GetTempPath()) "wss-doc-$([guid]::NewGuid())"
        New-Item -ItemType Directory -Path $Dir | Out-Null
        Add-Type -AssemblyName System.IO.Compression
        function New-Zip($path, [hashtable]$entries) {
            $fs = [IO.File]::Create($path)
            $zip = New-Object IO.Compression.ZipArchive($fs, [IO.Compression.ZipArchiveMode]::Create)
            foreach ($k in $entries.Keys) {
                $w = New-Object IO.StreamWriter($zip.CreateEntry($k).Open())
                $w.Write($entries[$k]); $w.Dispose()
            }
            $zip.Dispose(); $fs.Dispose()
        }
    }
    AfterAll { Remove-Item $Dir -Recurse -Force -ErrorAction SilentlyContinue }
    It 'reads UTF-8 text' {
        $p = Join-Path $Dir 'a.txt'
        [IO.File]::WriteAllText($p, "Grüße`nline2", (New-Object Text.UTF8Encoding($false)))
        Get-WssDocumentText $p | Should -Be "Grüße`nline2"
    }
    It 'reads UTF-16 text' {
        $p = Join-Path $Dir 'u.txt'
        [IO.File]::WriteAllText($p, 'hello', [Text.Encoding]::Unicode)
        Get-WssDocumentText $p | Should -Be 'hello'
    }
    It 'rejects binary files' {
        $p = Join-Path $Dir 'b.bin'
        [IO.File]::WriteAllBytes($p, [byte[]](1, 0, 2, 3))
        { Get-WssDocumentText $p } | Should -Throw '*binary*'
    }
    It 'extracts docx text' {
        $p = Join-Path $Dir 'd.docx'
        New-Zip $p @{ 'word/document.xml' = '<w:document><w:body><w:p><w:r><w:t>Hello &amp; welcome</w:t></w:r></w:p><w:p><w:r><w:t>Second</w:t></w:r></w:p></w:body></w:document>' }
        Get-WssDocumentText $p | Should -Be "Hello & welcome`nSecond"
    }
    It 'extracts xlsx cells' {
        $p = Join-Path $Dir 'x.xlsx'
        New-Zip $p @{
            'xl/sharedStrings.xml'     = '<sst><si><t>Name</t></si><si><t>Total</t></si></sst>'
            'xl/worksheets/sheet1.xml' = '<worksheet><sheetData><row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c></row><row r="2"><c r="A2" t="inlineStr"><is><t>Bob</t></is></c><c r="B2"><v>42</v></c></row></sheetData></worksheet>'
        }
        $text = Get-WssDocumentText $p
        $text | Should -Match "Name`tTotal"
        $text | Should -Match "Bob`t42"
    }
    It 'extracts pptx slides in order' {
        $p = Join-Path $Dir 'p.pptx'
        New-Zip $p @{
            'ppt/slides/slide2.xml'  = '<p:sld><a:p><a:r><a:t>Two</a:t></a:r></a:p></p:sld>'
            'ppt/slides/slide10.xml' = '<p:sld><a:p><a:r><a:t>Ten</a:t></a:r></a:p></p:sld>'
            'ppt/slides/slide1.xml'  = '<p:sld><a:p><a:r><a:t>One</a:t></a:r></a:p></p:sld>'
        }
        $text = Get-WssDocumentText $p
        $text.IndexOf('One') | Should -BeLessThan $text.IndexOf('Two')
        $text.IndexOf('Two') | Should -BeLessThan $text.IndexOf('Ten')
    }
}

Describe 'MCP protocol' {
    It 'answers initialize with negotiated version' {
        $r = Invoke-WssMessageLine '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05"}}' | ConvertFrom-Json
        $r.id | Should -Be 1
        $r.result.protocolVersion | Should -Be '2024-11-05'
        $r.result.serverInfo.name | Should -Be 'windows-server-search'
        $r.result.capabilities.tools | Should -Not -BeNullOrEmpty
    }
    It 'falls back to the latest supported version' {
        $r = Invoke-WssMessageLine '{"jsonrpc":"2.0","id":"a","method":"initialize","params":{"protocolVersion":"1999-01-01"}}' | ConvertFrom-Json
        $r.id | Should -Be 'a'
        $r.result.protocolVersion | Should -Be '2025-06-18'
    }
    It 'ignores notifications' {
        Invoke-WssMessageLine '{"jsonrpc":"2.0","method":"notifications/initialized"}' | Should -BeNullOrEmpty
    }
    It 'lists tools with schemas' {
        $r = Invoke-WssMessageLine '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | ConvertFrom-Json
        @($r.result.tools.name) | Should -Be @('list_servers', 'search_files', 'read_file', 'list_directory')
        foreach ($t in $r.result.tools) { $t.inputSchema.type | Should -Be 'object' }
        @(($r.result.tools | Where-Object name -eq 'read_file').inputSchema.required) | Should -Be @('path')
    }
    It 'returns tool errors as isError results' {
        Set-TestBackend
        $r = Invoke-WssMessageLine '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"search_files","arguments":{"query":"x"}}}' | ConvertFrom-Json
        $r.result.isError | Should -BeTrue
        $r.result.content[0].text | Should -Match 'No Windows servers'
    }
    It 'calls a tool successfully' {
        Set-TestBackend -Drives @(@{ Drive = 'Z:'; Unc = '\\fs01\p' })
        $r = Invoke-WssMessageLine '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"list_servers","arguments":{}}}' | ConvertFrom-Json
        $r.result.isError | Should -BeFalse
        $payload = $r.result.content[0].text | ConvertFrom-Json
        $payload.servers[0].name | Should -Be 'fs01'
        @($payload.servers[0].shares[0].drives) | Should -Be @('Z:')
    }
    It 'rejects unknown tools and methods' {
        (Invoke-WssMessageLine '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"nope"}}' | ConvertFrom-Json).error.code | Should -Be -32602
        (Invoke-WssMessageLine '{"jsonrpc":"2.0","id":6,"method":"nope"}' | ConvertFrom-Json).error.code | Should -Be -32601
    }
    It 'handles malformed JSON' {
        (Invoke-WssMessageLine '{not json' | ConvertFrom-Json).error.code | Should -Be -32700
    }
    It 'answers ping' {
        (Invoke-WssMessageLine '{"jsonrpc":"2.0","id":7,"method":"ping"}' | ConvertFrom-Json).id | Should -Be 7
    }
}
