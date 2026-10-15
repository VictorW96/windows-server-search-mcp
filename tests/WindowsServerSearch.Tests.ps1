# Unit tests - run anywhere PowerShell runs (Windows PowerShell 5.1, pwsh on Linux/macOS).
#   Invoke-Pester ./tests -Output Detailed

BeforeAll {
    $env:WSS_LOG_LEVEL = 'silent'
    Import-Module (Join-Path $PSScriptRoot '../server/WindowsServerSearch.psm1') -Force -DisableNameChecking
    $script:Mod = Get-Module WindowsServerSearch

    function Set-TestBackend {
        param($Drives = @(), $Shares = @{}, $Rows = @{}, $Errors = @{}, $Registry = @(), $Policies = @{})
        & $script:Mod {
            param($Drives, $Shares, $Rows, $Errors, $Registry, $Policies)
            $script:TestDrives = $Drives; $script:TestShares = $Shares; $script:TestRows = $Rows; $script:TestErrors = $Errors
            $script:TestRegistry = $Registry; $script:TestPolicies = $Policies
            $script:TestSql = New-Object System.Collections.ArrayList
            $script:DriveProvider = { $script:TestDrives }
            $script:PolicyCache = @{}
            $script:RegistryPolicyProvider = { @($script:TestRegistry) }
            $script:PolicyFileReader = {
                param($u)
                foreach ($k in $script:TestPolicies.Keys) { if ($k -ieq $u) { return $script:TestPolicies[$k] } }
                @{ Status = 'none' }
            }
            $script:ShareProvider = { param($h) foreach ($k in $script:TestShares.Keys) { if ($k -ieq $h) { return $script:TestShares[$k] } }; @() }
            $script:QueryExecutor = {
                param($m, $sql, $t)
                [void]$script:TestSql.Add(@{ Machine = $m; Sql = $sql })
                foreach ($k in $script:TestErrors.Keys) { if ($k -ieq $m) { throw $script:TestErrors[$k] } }
                foreach ($k in $script:TestRows.Keys) { if ($k -ieq $m) { return $script:TestRows[$k] } }
                @()
            }
        } $Drives $Shares $Rows $Errors $Registry $Policies
    }
    function Get-TestSql { & $script:Mod { @($script:TestSql) } }
    function New-TestConfig {
        param($Servers = @(), $AutoDiscover = $true, $Exclude = @(), $MaxResults = 50, $Deny = @())
        @{ Servers = @($Servers); AutoDiscover = $AutoDiscover; Exclude = @($Exclude); MaxResults = $MaxResults; QueryTimeout = 5; UseNetBios = $true; Deny = @($Deny); PolicyTtl = 0; MaxCopyMB = 500; WriteEnabled = $false; WriteAllowOverwrite = $false; WriteMaxMB = 100 }
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
    It 'reads the JSON config file' {
        '{"servers":["\\\\fs09\\x"],"maxResults":7,"autoDiscover":false}' | Set-Content -LiteralPath $env:WSS_CONFIG_FILE
        $c = Get-WssConfig
        $c.Servers | Should -Be @('\\fs09\x')
        $c.MaxResults | Should -Be 7
        $c.AutoDiscover | Should -BeFalse
    }
    It 'config file beats plugin defaults (Cowork cannot edit plugin options)' {
        '{"maxResults":7,"autoDiscover":false,"downloadDir":"C:\\dl"}' | Set-Content -LiteralPath $env:WSS_CONFIG_FILE
        # what Cowork passes: the plugin defaults
        $env:WSS_MAX_RESULTS = '50'; $env:WSS_AUTO_DISCOVER = 'true'; $env:WSS_DOWNLOAD_DIR = ''
        $c = Get-WssConfig
        $c.MaxResults | Should -Be 7
        $c.AutoDiscover | Should -BeFalse
        $c.DownloadDir | Should -Be 'C:\dl'
        Remove-Item env:WSS_DOWNLOAD_DIR -ErrorAction SilentlyContinue
    }
    It 'merges list settings from plugin options and config file' {
        '{"servers":["\\\\fs09\\x"],"deny":["**\\HR","**\\Personal"]}' | Set-Content -LiteralPath $env:WSS_CONFIG_FILE
        $env:WSS_SERVERS = '\\fs01\a;\\fs09\x'
        $env:WSS_DENY = '*.kdbx'
        $c = Get-WssConfig
        $c.Servers | Should -Be @('\\fs01\a', '\\fs09\x')
        $c.Deny | Should -Be @('*.kdbx', '**\HR', '**\Personal')
        Remove-Item env:WSS_DENY -ErrorAction SilentlyContinue
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
    It 'refuses paths on shares that are not known (their policy files would not be loaded)' {
        { Search-Wss -Arguments @{ query = 'plan'; path = '\\fs01\salaries' } -Config (New-TestConfig) } | Should -Throw '*outside*'
        { Search-Wss -Arguments @{ query = 'plan'; path = '\\fs01\C$\Users' } -Config (New-TestConfig) } | Should -Throw '*outside*'
        { Search-Wss -Arguments @{ query = 'plan'; path = '\\fs02\hr' } -Config (New-TestConfig -Exclude @('\\fs02\hr')) } | Should -Throw '*outside*'
        @(Get-TestSql).Count | Should -Be 0
    }
    It 'reports partial failures and keeps other results' {
        Set-TestBackend -Drives @(@{ Drive = 'Z:'; Unc = '\\fs01\p' }, @{ Drive = 'Y:'; Unc = '\\fs02\hr' }) -Rows @{ fs01 = @(@{ 'System.ItemUrl' = 'file://fs01/p/x.txt'; 'System.FileName' = 'x.txt' }) } -Errors @{ fs02 = 'boom 0x80040E37' }
        $r = Search-Wss -Arguments @{ query = 'x' } -Config (New-TestConfig)
        $r.result_count | Should -Be 1
        $r.errors[0].server | Should -Be 'fs02'
        $r.errors[0].error | Should -Match 'Windows Search Service'
        $r.errors[0].error | Should -Match 'DFS'
    }
    It 'gives error-specific hints and only blames the search service where plausible' {
        $err = { param($ex) [Management.Automation.ErrorRecord]::new($ex, 'x', 'NotSpecified', $null) }
        $denied = Get-WssErrorMessage (& $err ([Runtime.InteropServices.COMException]::new('Access is denied.', [int]0x80070005))) 'fs01'
        $denied | Should -Match '\(error 0x80070005\)'
        $denied | Should -Match 'permission problem'
        $denied | Should -Not -Match 'not running'
        $wrapped = [Management.Automation.MethodInvocationException]::new('Exception calling "Open"', [Runtime.InteropServices.COMException]::new('Unspecified', [int]0x80040154))
        $client = Get-WssErrorMessage (& $err $wrapped) 'fs01'
        $client | Should -Match '0x80040154'
        $client | Should -Match 'on this PC, not on the file server'
        $other = Get-WssErrorMessage (& $err ([Exception]::new('Item not found'))) 'fs01'
        $other | Should -Be 'Item not found'
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
        (Get-TestSql)[0].Sql | Should -Match '^SELECT TOP 23 ' -Because 'limit*3+20 rows are examined so blocked files do not crowd out allowed ones'
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

Describe 'copy_file helpers' {
    BeforeAll {
        $script:Base = Join-Path ([IO.Path]::GetTempPath()) "wss-copy-$([guid]::NewGuid())"
        New-Item -ItemType Directory -Path (Join-Path $Base 'src') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $Base 'dst') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $Base 'src/report.pdf') -Value 'PDFDATA'
        (Get-Item (Join-Path $Base 'src/report.pdf')).LastWriteTimeUtc = [datetime]'2020-01-02T03:04:05Z'
    }
    AfterAll { Remove-Item $Base -Recurse -Force -ErrorAction SilentlyContinue }

    It 'copies a file and preserves the modified time' {
        $r = Copy-WssOneFile -Source (Join-Path $Base 'src/report.pdf') -DestinationDir (Join-Path $Base 'dst')
        $r.local_path | Should -Be (Join-Path $Base 'dst/report.pdf')
        Get-Content -LiteralPath $r.local_path | Should -Be 'PDFDATA'
        (Get-Item $r.local_path).LastWriteTimeUtc | Should -Be ([datetime]'2020-01-02T03:04:05Z').ToUniversalTime()
        $r.Contains('renamed_to') | Should -BeFalse
    }
    It 'never overwrites by default but creates a numbered copy' {
        $r = Copy-WssOneFile -Source (Join-Path $Base 'src/report.pdf') -DestinationDir (Join-Path $Base 'dst')
        $r.renamed_to | Should -Be 'report (1).pdf'
        $r2 = Copy-WssOneFile -Source (Join-Path $Base 'src/report.pdf') -DestinationDir (Join-Path $Base 'dst')
        $r2.renamed_to | Should -Be 'report (2).pdf'
    }
    It 'overwrites when asked' {
        Set-Content -LiteralPath (Join-Path $Base 'dst/report.pdf') -Value 'OLD'
        $r = Copy-WssOneFile -Source (Join-Path $Base 'src/report.pdf') -DestinationDir (Join-Path $Base 'dst') -Overwrite $true
        $r.local_path | Should -Be (Join-Path $Base 'dst/report.pdf')
        Get-Content -LiteralPath $r.local_path | Should -Be 'PDFDATA'
    }
    It 'enforces the size limit and rejects folders' {
        { Copy-WssOneFile -Source (Join-Path $Base 'src/report.pdf') -DestinationDir (Join-Path $Base 'dst') -MaxBytes 2 } | Should -Throw '*copy limit*'
        { Copy-WssOneFile -Source (Join-Path $Base 'src') -DestinationDir (Join-Path $Base 'dst') } | Should -Throw '*is a folder*'
        { Copy-WssOneFile -Source (Join-Path $Base 'src/missing.pdf') -DestinationDir (Join-Path $Base 'dst') } | Should -Throw '*not found*'
    }
    It 'finds the workspace folder by marker file' {
        $ws = Join-Path $Base 'profile/Documents/Claude/My Project'
        New-Item -ItemType Directory -Path $ws -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $Base 'profile/AppData/x') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $Base 'profile/AppData/x/.wss-target-abc12345') -Value ''
        Set-Content -LiteralPath (Join-Path $ws '.wss-target-abc12345') -Value ''
        Find-WssMarkerDirectory -Marker '.wss-target-abc12345' -Roots @(Join-Path $Base 'profile') | Should -Be $ws
    }
    It 'rejects bad or unknown markers' {
        { Find-WssMarkerDirectory -Marker '../etc' -Roots @($Base) } | Should -Throw '*Invalid marker*'
        { Find-WssMarkerDirectory -Marker 'short' -Roots @($Base) } | Should -Throw '*Invalid marker*'
        { Find-WssMarkerDirectory -Marker '.wss-short' -Roots @($Base) } | Should -Throw '*Invalid marker*'
        { Find-WssMarkerDirectory -Marker '.wss-target-nothere99' -Roots @($Base) } | Should -Throw '*Could not find*'
    }
    It 'does not accept ordinary files as markers: <marker>' -TestCases @(
        @{ marker = '.gitconfig' }, @{ marker = 'desktop.ini' }, @{ marker = 'ntuser.ini' }, @{ marker = 'NTUSER.DAT' }
    ) {
        $p = Join-Path $Base 'profile2'
        New-Item -ItemType Directory -Path $p -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $p $marker) -Value 'x'
        { Find-WssMarkerDirectory -Marker $marker -Roots @($p) } | Should -Throw '*Invalid marker*'
    }
    It 'refuses markers in broad folders (profile root, Documents, ...)' {
        $p = Join-Path $Base 'profile3'
        New-Item -ItemType Directory -Path (Join-Path $p 'Documents') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $p '.wss-target-root1234') -Value ''
        Set-Content -LiteralPath (Join-Path $p 'Documents/.wss-target-docs1234') -Value ''
        { Find-WssMarkerDirectory -Marker '.wss-target-root1234' -Roots @($p) } | Should -Throw '*too broad*'
        { Find-WssMarkerDirectory -Marker '.wss-target-docs1234' -Roots @($p) } | Should -Throw '*too broad*'
    }
    It 'refuses marker files with content' {
        $ws = Join-Path $Base 'profile4/Documents/Claude'
        New-Item -ItemType Directory -Path $ws -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $ws '.wss-target-full1234') -Value ('x' * 2000)
        { Find-WssMarkerDirectory -Marker '.wss-target-full1234' -Roots @(Join-Path $Base 'profile4') } | Should -Throw '*not an empty marker*'
    }
    It 'refuses system, configuration and dot folders as copy destinations' {
        $home_ = [Environment]::GetFolderPath('UserProfile')
        { Assert-WssSafeLocalDestination $home_ } | Should -Throw '*configuration folder*'
        { Assert-WssSafeLocalDestination (Join-Path $home_ '.ssh') } | Should -Throw '*configuration folder*'
        { Assert-WssSafeLocalDestination (Join-Path $home_ '.claude/plugins/x') } | Should -Throw '*configuration folder*'
        { Assert-WssSafeLocalDestination (Join-Path $home_ 'Documents/Claude/ws') } | Should -Not -Throw
        { Assert-WssSafeLocalDestination (Join-Path $Base 'dst') } | Should -Not -Throw -Because 'the temp folder is allowed'
        if ($IsWindows -or $PSVersionTable.PSVersion.Major -lt 6) {
            { Assert-WssSafeLocalDestination ([Environment]::GetFolderPath('Startup')) } | Should -Throw '*configuration folder*'
            { Assert-WssSafeLocalDestination (Join-Path $env:APPDATA 'Claude') } | Should -Throw '*configuration folder*'
            { Assert-WssSafeLocalDestination (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps') } | Should -Throw '*configuration folder*'
            { Assert-WssSafeLocalDestination (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WindowsPowerShell') } | Should -Throw '*configuration folder*'
            { Assert-WssSafeLocalDestination $env:SystemRoot } | Should -Throw '*configuration folder*'
            { Assert-WssSafeLocalDestination 'C:\' } | Should -Throw '*configuration folder*'
        }
    }
    It 'copies programs and scripts only into the workspace or download folder' {
        Set-TestBackend -Drives @(@{ Drive = 'Z:'; Unc = '\\fs01\p' })
        { Copy-WssFiles -Arguments @{ path = '\\fs01\p\run.ps1'; destination = (Join-Path $Base 'dst') } -Config (New-TestConfig) } | Should -Throw '*programs and scripts*'
        { Copy-WssFiles -Arguments @{ path = '\\fs01\p\x\Setup.EXE'; destination = (Join-Path $Base 'dst') } -Config (New-TestConfig) } | Should -Throw '*programs and scripts*'
    }
    It 'validates local destinations' {
        { Resolve-WssLocalDestination '' @() } | Should -Throw
        if ($IsWindows -or $PSVersionTable.PSVersion.Major -lt 6) {
            { Resolve-WssLocalDestination '\\fs01\share\x' @() } | Should -Throw '*network path*'
            { Resolve-WssLocalDestination 'relative\dir' @() } | Should -Throw '*absolute*'
            $t = @(@{ Name = 'fs01'; Machine = 'fs01'; Shares = @(@{ Unc = '\\fs01\p'; Drives = @('Q:') }) })
            { Resolve-WssLocalDestination 'Q:\x' $t } | Should -Throw '*mapped network drive*'
            Resolve-WssLocalDestination '%TEMP%\x' @() | Should -Be ([IO.Path]::GetFullPath((Join-Path $env:TEMP 'x')))
        } else {
            { Resolve-WssLocalDestination 'relative/dir' @() } | Should -Throw '*absolute*'
            Resolve-WssLocalDestination '/tmp/x/../y' @() | Should -Be '/tmp/y'
        }
    }
    It 'requires a source path' {
        Set-TestBackend -Drives @(@{ Drive = 'Z:'; Unc = '\\fs01\p' })
        { Copy-WssFiles -Arguments @{} -Config (New-TestConfig) } | Should -Throw '*Provide path*'
    }
    It 'reports per-file errors when nothing could be copied' {
        Set-TestBackend -Drives @(@{ Drive = 'Z:'; Unc = '\\fs01\p' })
        $cfg = New-TestConfig; $cfg.MaxCopyMB = 1
        { Copy-WssFiles -Arguments @{ paths = @('\\evil\x\y.pdf'); destination = (Join-Path $Base 'dst') } -Config $cfg } | Should -Throw '*outside the known*'
    }
    It 'refuses to copy into the plugin configuration folder' {
        Set-TestBackend -Drives @(@{ Drive = 'Z:'; Unc = '\\fs01\p' })
        $cfg = New-TestConfig; $cfg.ConfigFile = (Join-Path $Base 'cfgdir/config.json')
        { Copy-WssFiles -Arguments @{ path = '\\fs01\p\config.json'; destination = (Join-Path $Base 'cfgdir') } -Config $cfg } | Should -Throw '*configuration folder*'
        { Copy-WssFiles -Arguments @{ path = '\\fs01\p\config.json'; destination = (Join-Path $Base 'cfgdir'); subfolder = 'x' } -Config $cfg } | Should -Throw '*configuration folder*'
    }
    It 'rejects subfolder traversal' {
        Set-TestBackend -Drives @(@{ Drive = 'Z:'; Unc = '\\fs01\p' })
        $cfg = New-TestConfig; $cfg.MaxCopyMB = 1
        { Copy-WssFiles -Arguments @{ path = '\\fs01\p\a.pdf'; destination = (Join-Path $Base 'dst'); subfolder = '../escape' } -Config $cfg } | Should -Throw '*Invalid subfolder*'
    }
}

Describe 'Access policy: patterns' {
    BeforeAll {
        function Test-Pattern([string]$Pattern, [string]$Path, [string]$ShareRoot = $null) {
            $t = @(@{ Name = 'fs01'; Machine = 'fs01'; Shares = @(@{ Name = 'data'; Unc = '\\fs01\data'; Drives = @('Z:') }) })
            $rule = New-WssPolicyRule -Pattern $Pattern -Source 'test' -ShareRoot $ShareRoot -Targets $t
            $rule.Regex.IsMatch((Get-WssCanonicalUnc $Path))
        }
    }
    It '<pattern> vs <path> -> <expected>' -TestCases @(
        @{ pattern = '\\fs01\hr\**'; path = '\\fs01\hr\a\b.txt'; expected = $true }
        @{ pattern = '\\fs01\hr'; path = '\\FS01.corp.local\HR\x.docx'; expected = $true }
        @{ pattern = '\\fs01\hr'; path = '\\fs01\hr'; expected = $true }
        @{ pattern = '\\fs01\hr'; path = '\\fs01\hrx\a.txt'; expected = $false }
        @{ pattern = '\\fs01\hr'; path = '\\fs02\hr\a.txt'; expected = $false }
        @{ pattern = '\\*\hr'; path = '\\fs02\hr\a.txt'; expected = $true }
        @{ pattern = '**\Personal\**'; path = '\\fs01\data\Team\Personal\x.txt'; expected = $true }
        @{ pattern = '**\Personal'; path = '\\fs01\data\Personal'; expected = $true }
        @{ pattern = 'Personal'; path = '\\fs01\Personal\x'; expected = $true }
        @{ pattern = '**\Personal\**'; path = '\\fs01\data\Personalities\x.txt'; expected = $false }
        @{ pattern = '**\*.kdbx'; path = '\\fs01\data\a\vault.KDBX'; expected = $true }
        @{ pattern = '*.kdbx'; path = '\\fs01\data\a\vault.kdbx.txt'; expected = $false }
        @{ pattern = '\\fs01\data\*\Contracts\**'; path = '\\fs01\data\ProjA\Contracts\c.pdf'; expected = $true }
        @{ pattern = '\\fs01\data\*\Contracts\**'; path = '\\fs01\data\ProjA\Sub\Contracts\c.pdf'; expected = $false }
        @{ pattern = '\\fs01\data\**\Contracts'; path = '\\fs01\data\ProjA\Sub\Contracts\c.pdf'; expected = $true }
        @{ pattern = '\\fs01\data\Pay?oll*'; path = '\\fs01\data\Payroll 2024\x.xlsx'; expected = $true }
        @{ pattern = 'Z:\Finance'; path = '\\fs01\data\finance\q1.xlsx'; expected = $true }
        @{ pattern = '//fs01/data/finance/'; path = '\\fs01\data\Finance\q1.xlsx'; expected = $true }
        @{ pattern = 'a+b (1).txt'; path = '\\fs01\data\x\a+b (1).txt'; expected = $true }
        @{ pattern = 'a+b (1).txt'; path = '\\fs01\data\x\aab (1).txt'; expected = $false }
    ) {
        Test-Pattern $pattern $path | Should -Be $expected
    }
    It 'share policy (gitignore) semantics: <pattern> vs <path> -> <expected>' -TestCases @(
        @{ pattern = 'secret'; path = '\\fs01\data\secret\x.txt'; expected = $true }
        @{ pattern = 'secret'; path = '\\fs01\data\a\b\secret\x.txt'; expected = $true }
        @{ pattern = 'secret/'; path = '\\fs01\data\a\secret\x.txt'; expected = $true }
        @{ pattern = '/secret'; path = '\\fs01\data\a\secret\x.txt'; expected = $false }
        @{ pattern = '/secret'; path = '\\fs01\data\secret\x.txt'; expected = $true }
        @{ pattern = 'a/secret'; path = '\\fs01\data\a\secret'; expected = $true }
        @{ pattern = 'a/secret'; path = '\\fs01\data\b\a\secret'; expected = $false }
        @{ pattern = '*.hidden.txt'; path = '\\fs01\data\x\y.hidden.txt'; expected = $true }
        @{ pattern = '**/drafts/**'; path = '\\fs01\data\p\drafts\d.docx'; expected = $true }
        @{ pattern = 'secret'; path = '\\fs01\other\secret\x.txt'; expected = $false }
        @{ pattern = 'secret'; path = '\\fs01.corp\DATA\Secret\x.txt'; expected = $true }
    ) {
        Test-Pattern $pattern $path '\\fs01\data' | Should -Be $expected
    }
    It 'rejects invalid patterns' {
        { New-WssPolicyRule -Pattern 'a|b' -Source t } | Should -Throw
        { New-WssPolicyRule -Pattern '   ' -Source t } | Should -Throw
        { New-WssPolicyRule -Pattern '/' -Source t -ShareRoot '\\fs01\data' } | Should -Throw
        { New-WssPolicyRule -Pattern 'Q:\x' -Source t -Targets @() } | Should -Throw '*not a mapped drive*'
    }
}

Describe 'Access policy: canonical paths' {
    It 'normalises <path>' -TestCases @(
        @{ path = '\\FS01.corp.local\Data\A\B.txt'; expected = '\\fs01\data\a\b.txt' }
        @{ path = '\\fs01\data\a\..\secret\x.txt'; expected = '\\fs01\data\secret\x.txt' }
        @{ path = '\\fs01\data\secret.\x.txt. '; expected = '\\fs01\data\secret\x.txt' }
        @{ path = '\\fs01\data\secret\x.txt:hidden:$DATA'; expected = '\\fs01\data\secret\x.txt' }
        @{ path = '//fs01/data//secret/./x.txt'; expected = '\\fs01\data\secret\x.txt' }
        @{ path = '\\fs01\data\..\..\x'; expected = '\\fs01\data\x' }
    ) {
        Get-WssCanonicalUnc $path | Should -Be $expected
    }
}

Describe 'Access policy: sources and enforcement' {
    It 'parses gitignore-style policy files' {
        $r = ConvertFrom-WssPolicyText "# comment`r`n`r`nsecret/`n  *.tmp  `n!keep.txt`n/top"
        $r.Patterns | Should -Be @('secret/', '*.tmp', '/top')
        $r.Warnings.Count | Should -Be 1
        { ConvertFrom-WssPolicyText "ok`nbad|line" } | Should -Throw '*line 2*'
    }
    It 'combines built-in, group policy, plugin and share policy rules' {
        Set-TestBackend -Drives @(@{ Drive = 'Z:'; Unc = '\\fs01\data' }) -Registry @('**\HR') -Policies @{ '\\fs01\data' = @{ Status = 'ok'; Content = "secret`n" } }
        $cfg = New-TestConfig -Deny @('**\Personal')
        $t = @(Get-WssTargets -Config $cfg)
        $p = Get-WssPolicy -Config $cfg -Targets $t
        $p.Counts['group-policy'] | Should -Be 1
        $p.Counts['plugin-config'] | Should -Be 1
        $p.Counts['share-policy'] | Should -Be 1
        $p.Counts['built-in'] | Should -BeGreaterThan 3
        (Test-WssBlocked '\\fs01\data\x\HR\a.txt' $p).Source | Should -Be 'group-policy'
        (Test-WssBlocked '\\fs01\data\Personal\a.txt' $p).Source | Should -Be 'plugin-config'
        (Test-WssBlocked '\\fs01\data\secret\a.txt' $p).Source | Should -Be 'share-policy \\fs01\data'
        (Test-WssBlocked '\\fs01\data\$RECYCLE.BIN\a.txt' $p).Source | Should -Be 'built-in'
        Test-WssBlocked '\\fs01\data\public\a.txt' $p | Should -BeNullOrEmpty
    }
    It 'fails closed when a share policy file is unreadable or invalid' {
        Set-TestBackend -Drives @(@{ Drive = 'Z:'; Unc = '\\fs01\data' }, @{ Drive = 'Y:'; Unc = '\\fs01\hr' }, @{ Drive = 'X:'; Unc = '\\fs01\ok' }) -Policies @{
            '\\fs01\data' = @{ Status = 'error'; Error = 'access denied' }
            '\\fs01\hr'   = @{ Status = 'ok'; Content = "bad<pattern" }
        }
        $cfg = New-TestConfig
        $p = Get-WssPolicy -Config $cfg -Targets @(Get-WssTargets -Config $cfg)
        @($p.BlockedShares).Count | Should -Be 2
        Test-WssBlocked '\\fs01\data\a.txt' $p | Should -Not -BeNullOrEmpty
        Test-WssBlocked '\\fs01\hr\a.txt' $p | Should -Not -BeNullOrEmpty
        Test-WssBlocked '\\fs01\ok\a.txt' $p | Should -BeNullOrEmpty
    }
    It 'invalid global patterns are reported but do not block everything' {
        Set-TestBackend -Drives @(@{ Drive = 'Z:'; Unc = '\\fs01\data' }) -Registry @('Q:\nope')
        $cfg = New-TestConfig
        $p = Get-WssPolicy -Config $cfg -Targets @(Get-WssTargets -Config $cfg)
        @($p.Warnings).Count | Should -Be 1
        Test-WssBlocked '\\fs01\data\a.txt' $p | Should -BeNullOrEmpty
    }
    It 'hides blocked search results and counts them' {
        $rows = @()
        foreach ($n in 'a.txt', 'secret\b.txt', 'c.txt', 'secret\d.txt', 'vault.kdbx') {
            $rows += @{ 'System.ItemUrl' = 'file://fs01/data/' + ($n -replace '\\', '/'); 'System.FileName' = (Split-Path $n -Leaf); 'System.Search.Rank' = 100 }
        }
        Set-TestBackend -Drives @(@{ Drive = 'Z:'; Unc = '\\fs01\data' }) -Rows @{ fs01 = $rows } -Policies @{ '\\fs01\data' = @{ Status = 'ok'; Content = 'secret' } }
        $r = Search-Wss -Arguments @{ query = 'x' } -Config (New-TestConfig)
        $r.hidden_by_policy | Should -Be 3
        $r.policy_note | Should -Match '^3 matching file'
        @($r.results | ForEach-Object { $_.name }) | Should -Be @('a.txt', 'c.txt')
    }
    It 'widens the query when blocked results crowd out allowed ones' {
        $rows = @()
        for ($i = 0; $i -lt 23; $i++) { $rows += @{ 'System.ItemUrl' = "file://fs01/data/secret/$i.txt"; 'System.FileName' = "$i.txt" } }
        Set-TestBackend -Drives @(@{ Drive = 'Z:'; Unc = '\\fs01\data' }) -Rows @{ fs01 = $rows } -Policies @{ '\\fs01\data' = @{ Status = 'ok'; Content = 'secret' } }
        $r = Search-Wss -Arguments @{ query = 'x'; max_results = 1 } -Config (New-TestConfig)
        @(Get-TestSql).Count | Should -Be 2
        (Get-TestSql)[1].Sql | Should -Match '^SELECT TOP 92 '
        $r.result_count | Should -Be 0
    }
    It 'refuses to search inside a blocked folder' {
        Set-TestBackend -Drives @(@{ Drive = 'Z:'; Unc = '\\fs01\data' }) -Policies @{ '\\fs01\data' = @{ Status = 'ok'; Content = 'secret' } }
        { Search-Wss -Arguments @{ query = 'x'; path = 'Z:\a\Secret\sub' } -Config (New-TestConfig) } | Should -Throw '*blocked by the access policy*'
    }
    It 'skips blocked shares entirely' {
        Set-TestBackend -Drives @(@{ Drive = 'Z:'; Unc = '\\fs01\data' }, @{ Drive = 'Y:'; Unc = '\\fs02\hr' }) -Registry @('\\fs02\hr')
        $null = Search-Wss -Arguments @{ query = 'x' } -Config (New-TestConfig)
        @(Get-TestSql | ForEach-Object { $_.Machine }) | Should -Be @('fs01')
    }
    It 'refuses read_file, copy_file and list_directory on blocked paths' {
        Set-TestBackend -Drives @(@{ Drive = 'Z:'; Unc = '\\fs01\data' }) -Policies @{ '\\fs01\data' = @{ Status = 'ok'; Content = 'secret' } }
        $cfg = New-TestConfig
        { Read-WssFile -Arguments @{ path = 'Z:\secret\a.txt' } -Config $cfg } | Should -Throw '*blocked by the access policy*'
        { Read-WssFile -Arguments @{ path = 'Z:\x\..\SECRET.\a.txt' } -Config $cfg } | Should -Throw '*blocked by the access policy*'
        { Get-WssDirectoryListing -Arguments @{ path = 'Z:\secret' } -Config $cfg } | Should -Throw '*blocked by the access policy*'
        { Copy-WssFiles -Arguments @{ path = 'Z:\secret\a.pdf'; destination = [IO.Path]::GetTempPath() } -Config $cfg } | Should -Throw '*blocked by the access policy*'
    }
    It 'shows the policy in list_servers' {
        Set-TestBackend -Drives @(@{ Drive = 'Z:'; Unc = '\\fs01\data' }, @{ Drive = 'Y:'; Unc = '\\fs01\hr' }) -Registry @('\\fs01\hr') -Policies @{ '\\fs01\data' = @{ Status = 'ok'; Content = "secret`n*.tmp" } }
        $r = Get-WssServerList -Arguments @{} -Config (New-TestConfig)
        $r.access_policy.rule_counts['share-policy'] | Should -Be 2
        $r.access_policy.policy_files[0].share | Should -Be '\\fs01\data'
        ($r.servers[0].shares | Where-Object name -eq 'hr').blocked_by_policy | Should -Match 'group-policy'
    }
}

Describe 'save_file' {
    BeforeAll {
        $script:WBase = Join-Path ([IO.Path]::GetTempPath()) "wss-write-$([guid]::NewGuid())"
        New-Item -ItemType Directory -Path $WBase -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $WBase 'src.txt') -Value 'SOURCE'
    }
    AfterAll {
        Remove-Item $WBase -Recurse -Force -ErrorAction SilentlyContinue
        & (Get-Module WindowsServerSearch) { $script:RegistryWriteVetoProvider = $null }
    }
    It 'is enabled by default (with overwrite) and hidden from tools/list when disabled' {
        $c = Get-WssConfig
        $c.WriteEnabled | Should -BeTrue
        $c.WriteAllowOverwrite | Should -BeTrue
        @(Get-WssToolDefinitions | ForEach-Object { $_.name }) | Should -Not -Contain 'save_file'
        @(Get-WssToolDefinitions -IncludeWrite $true | ForEach-Object { $_.name }) | Should -Contain 'save_file'
        Set-TestBackend -Drives @(@{ Drive = 'Z:'; Unc = '\\fs01\p' })
        { Save-WssFiles -Arguments @{ destination = 'Z:\x'; name = 'a.txt'; content = 'x' } -Config (New-TestConfig) } | Should -Throw '*disabled*'
    }
    It 'can be enabled via the nested "write" object in the config file' {
        $f = Join-Path $WBase 'cfg.json'
        '{"write":{"enabled":true,"allowOverwrite":true,"maxMB":5,"logPath":"C:\\log.jsonl"}}' | Set-Content -LiteralPath $f
        $env:WSS_CONFIG_FILE = $f
        $env:WSS_WRITE_ENABLED = 'false'   # what the plugin default passes
        try {
            $c = Get-WssConfig
            $c.WriteEnabled | Should -BeTrue
            $c.WriteAllowOverwrite | Should -BeTrue
            $c.WriteMaxMB | Should -Be 5
            $c.WriteLogPath | Should -Be 'C:\log.jsonl'
        } finally { Remove-Item env:WSS_CONFIG_FILE, env:WSS_WRITE_ENABLED -ErrorAction SilentlyContinue }
    }
    It 'Group Policy veto wins over the configuration' {
        & (Get-Module WindowsServerSearch) { $script:RegistryWriteVetoProvider = { $true } }
        $cfg = New-TestConfig; $cfg.WriteEnabled = $true
        $st = Get-WssWriteStatus $cfg
        $st.enabled | Should -BeFalse
        $st.disabled_by_group_policy | Should -BeTrue
        { Save-WssFiles -Arguments @{ destination = 'Z:\x'; name = 'a.txt'; content = 'x' } -Config $cfg } | Should -Throw '*Group Policy*'
        & (Get-Module WindowsServerSearch) { $script:RegistryWriteVetoProvider = { $false } }
    }
    It 'writes content atomically and never leaves temp files' {
        $d = Join-Path $WBase 'out1'
        $r = Save-WssOneFile -TargetDir $d -Name 'summary.md' -Content "# Grüße"
        $r.target | Should -Be (Join-Path $d 'summary.md')
        [IO.File]::ReadAllText($r.target) | Should -Be '# Grüße'
        $r.overwritten | Should -BeFalse
        @(Get-ChildItem -LiteralPath $d -Force | Where-Object Name -like '.~claude-upload-*').Count | Should -Be 0
    }
    It 'creates numbered copies instead of overwriting' {
        $d = Join-Path $WBase 'out1'
        $r = Save-WssOneFile -TargetDir $d -Name 'summary.md' -Content 'second'
        $r.renamed_to | Should -Be 'summary (1).md'
        [IO.File]::ReadAllText((Join-Path $d 'summary.md')) | Should -Be '# Grüße'
    }
    It 'overwrites with a backup of the previous version' {
        $d = Join-Path $WBase 'out1'
        $r = Save-WssOneFile -TargetDir $d -Name 'summary.md' -Content 'third' -Overwrite $true
        $r.overwritten | Should -BeTrue
        [IO.File]::ReadAllText($r.target) | Should -Be 'third'
        $r.backup | Should -Match 'summary\.md\.claude-backup-\d{8}-\d{6}$'
        [IO.File]::ReadAllText($r.backup) | Should -Be '# Grüße'
    }
    It 'keeps the original file permissions on the new version and on the backup' -Skip:(-not ($IsWindows -or $PSVersionTable.PSVersion.Major -lt 6)) {
        $d = Join-Path $WBase 'acl'
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        $f = Join-Path $d 'restricted.txt'
        Set-Content -LiteralPath $f -Value 'original'
        $acl = Get-Acl -LiteralPath $f
        $acl.SetAccessRuleProtection($true, $false)   # no inherited permissions
        $me = [Security.Principal.WindowsIdentity]::GetCurrent().User
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($me, 'FullControl', 'Allow')))
        Set-Acl -LiteralPath $f -AclObject $acl
        $before = (Get-Acl -LiteralPath $f).GetSecurityDescriptorSddlForm('Access')

        $r = Save-WssOneFile -TargetDir $d -Name 'restricted.txt' -Content 'new' -Overwrite $true
        [IO.File]::ReadAllText($r.target) | Should -Be 'new'
        (Get-Acl -LiteralPath $r.target).GetSecurityDescriptorSddlForm('Access') | Should -Be $before
        (Get-Acl -LiteralPath $r.backup).GetSecurityDescriptorSddlForm('Access') | Should -Be $before
        ([IO.File]::GetAttributes($r.target) -band [IO.FileAttributes]::Hidden) | Should -Be 0
    }
    It 'copies source files and supports encodings and size limits' {
        $d = Join-Path $WBase 'out2'
        $r = Save-WssOneFile -TargetDir $d -Name 'copy.txt' -SourceFile (Join-Path $WBase 'src.txt')
        (Get-Content -LiteralPath $r.target) | Should -Be 'SOURCE'
        $r2 = Save-WssOneFile -TargetDir $d -Name 'bom.csv' -Content 'a;b' -Encoding 'utf8-bom'
        [IO.File]::ReadAllBytes($r2.target)[0..2] | Should -Be @(0xEF, 0xBB, 0xBF)
        { Save-WssOneFile -TargetDir $d -Name 'big.txt' -Content ('x' * 100) -MaxBytes 10 } | Should -Throw '*write limit*'
        { Save-WssOneFile -TargetDir $d -Name 'e.txt' -Content 'x' -Encoding 'latin1' } | Should -Throw '*Invalid encoding*'
    }
    It 'validates file names: <name>' -TestCases @(
        @{ name = 'a/b.txt' }, @{ name = '..\x.txt' }, @{ name = 'CON' }, @{ name = 'nul.txt' }, @{ name = 'x.txt.' }, @{ name = 'a:b' }, @{ name = '' }
    ) {
        { Test-WssFileName $name } | Should -Throw
    }
    It 'blocks policy files, executables and denied paths as targets' {
        Set-TestBackend -Drives @(@{ Drive = 'Z:'; Unc = '\\fs01\p' }) -Policies @{ '\\fs01\p' = @{ Status = 'ok'; Content = 'secret' } }
        $cfg = New-TestConfig
        $t = @(Get-WssTargets -Config $cfg)
        $pol = Get-WssPolicy -Config $cfg -Targets $t
        $wr = Get-WssWriteRules
        { Assert-WssWritable '\\fs01\p\.claude-policy' $pol $wr } | Should -Throw '*not allowed*'
        { Assert-WssWritable '\\fs01\p\sub\Tool.EXE' $pol $wr } | Should -Throw '*not allowed*'
        { Assert-WssWritable '\\fs01\p\run.ps1' $pol $wr } | Should -Throw '*not allowed*'
        { Assert-WssWritable '\\fs01\p\secret\a.txt' $pol $wr } | Should -Throw '*access policy*'
        { Assert-WssWritable '\\fs01\p\x\vault.kdbx' $pol $wr } | Should -Throw '*access policy*'
        { Assert-WssWritable '\\fs01\p\reports\summary.md' $pol $wr } | Should -Not -Throw
    }
    It 'only reads local sources from the workspace or download folder' {
        $roots = @((Join-Path $WBase 'ws'))
        New-Item -ItemType Directory -Path (Join-Path $WBase 'ws') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $WBase 'ws/ok.txt') -Value 'ok'
        Resolve-WssSaveSource (Join-Path $WBase 'ws/ok.txt') $roots | Should -Be ([IO.Path]::GetFullPath((Join-Path $WBase 'ws/ok.txt')))
        { Resolve-WssSaveSource (Join-Path $WBase 'src.txt') $roots } | Should -Throw '*outside the folders*'
        { Resolve-WssSaveSource (Join-Path $WBase 'ws/../src.txt') $roots } | Should -Throw '*outside the folders*'
        { Resolve-WssSaveSource (Join-Path $WBase 'ws/missing.txt') $roots } | Should -Throw '*not found*'
    }
    It 'refuses hidden files and dot folders as sources' {
        $ws = Join-Path $WBase 'ws2'
        New-Item -ItemType Directory -Path (Join-Path $ws '.ssh') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $ws '.ssh/id_ed25519') -Value 'KEY'
        Set-Content -LiteralPath (Join-Path $ws '.env') -Value 'SECRET=1'
        Set-Content -LiteralPath (Join-Path $ws 'hidden.txt') -Value 'h'
        [IO.File]::SetAttributes((Join-Path $ws 'hidden.txt'), [IO.FileAttributes]::Hidden)
        { Resolve-WssSaveSource (Join-Path $ws '.ssh/id_ed25519') @($ws) } | Should -Throw '*hidden*'
        { Resolve-WssSaveSource (Join-Path $ws '.env') @($ws) } | Should -Throw '*hidden*'
        if ($IsWindows -or $PSVersionTable.PSVersion.Major -lt 6) {
            { Resolve-WssSaveSource (Join-Path $ws 'hidden.txt') @($ws) } | Should -Throw '*hidden*'
        }
    }
    It 'requires a destination and a source' {
        Set-TestBackend -Drives @(@{ Drive = 'Z:'; Unc = '\\fs01\p' })
        $cfg = New-TestConfig; $cfg.WriteEnabled = $true
        & (Get-Module WindowsServerSearch) { $script:RegistryWriteVetoProvider = { $false } }
        { Save-WssFiles -Arguments @{ name = 'a.txt'; content = 'x' } -Config $cfg } | Should -Throw '*destination*'
        { Save-WssFiles -Arguments @{ destination = 'Z:\x' } -Config $cfg } | Should -Throw '*Provide content*'
        { Save-WssFiles -Arguments @{ destination = 'Z:\x'; content = 'x' } -Config $cfg } | Should -Throw '*name is required*'
        { Save-WssFiles -Arguments @{ destination = 'Z:\x'; source_name = 'a.txt' } -Config $cfg } | Should -Throw '*source_marker*'
        { Save-WssFiles -Arguments @{ destination = 'C:\local'; name = 'a.txt'; content = 'x' } -Config $cfg } | Should -Throw '*not a mapped drive*'
    }
    It 'reports write status in list_servers' {
        Set-TestBackend -Drives @(@{ Drive = 'Z:'; Unc = '\\fs01\p' })
        $cfg = New-TestConfig; $cfg.WriteEnabled = $true; $cfg.WriteAllowOverwrite = $true
        $r = Get-WssServerList -Arguments @{} -Config $cfg
        $r.write.enabled | Should -BeTrue
        $r.write.allow_overwrite | Should -BeTrue
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
        @($r.result.tools.name) | Should -Be @('list_servers', 'search_files', 'read_file', 'list_directory', 'copy_file', 'save_file')
        ($r.result.tools | Where-Object name -eq 'copy_file').annotations.readOnlyHint | Should -BeFalse
        ($r.result.tools | Where-Object name -eq 'copy_file').annotations.destructiveHint | Should -BeTrue
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
