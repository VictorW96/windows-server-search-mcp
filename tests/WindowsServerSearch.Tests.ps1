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
            $script:CompatLevel = @{}
            $script:TargetCache = $null
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
    It 'puts the user policy file next to the config file' {
        $c = Get-WssConfig
        $c.PolicyFile | Should -Be (Join-Path (Split-Path $env:WSS_CONFIG_FILE) '.claude-policy')
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
    It 'simplifies the query for compat levels' {
        $l1 = New-WssSearchSql -Machine 'm' -Query 'x' -Compat 1
        $l1 | Should -Match '^SELECT TOP 50 System\.ItemUrl, System\.ItemPathDisplay, System\.FileName, System\.Size, System\.DateModified FROM'
        $l1 | Should -Match 'ORDER BY System\.Search\.Rank DESC$'
        New-WssSearchSql -Machine 'm' -Query 'x' -Compat 2 | Should -Match 'ORDER BY System\.DateModified DESC$'
        New-WssSearchSql -Machine 'm' -Query 'x' -Sort name -Compat 2 | Should -Match 'ORDER BY System\.FileName ASC$'
        New-WssSearchSql -Machine 'm' -Query 'x' -Compat 3 | Should -Not -Match 'ORDER BY'
    }
    It 'excludes folders by default' {
        New-WssSearchSql -Machine 'm' -Query 'x' | Should -Match "System\.ItemType <> 'Directory'"
        New-WssSearchSql -Machine 'm' -Query 'x' -IncludeFolders $true | Should -Not -Match 'Directory'
    }
}

Describe 'Restore-WssEnvironment' {
    AfterEach {
        foreach ($k in 'WSS_TEST_MISSING', 'WSS_TEST_SET', 'WSS_TEST_EXPAND') { [Environment]::SetEnvironmentVariable($k, $null, 'Process') }
    }
    It 'adds missing variables, keeps existing ones and expands references' {
        [Environment]::SetEnvironmentVariable('WSS_TEST_SET', 'keep', 'Process')
        $added = Restore-WssEnvironment -Defaults ([ordered]@{ WSS_TEST_MISSING = 'C:\Win'; WSS_TEST_SET = 'other'; WSS_TEST_EXPAND = '%WSS_TEST_MISSING%\System32'; Path = 'x' })
        @($added) | Should -Be @('WSS_TEST_MISSING', 'WSS_TEST_EXPAND')
        $env:WSS_TEST_MISSING | Should -Be 'C:\Win'
        $env:WSS_TEST_SET | Should -Be 'keep'
        $env:WSS_TEST_EXPAND | Should -Be 'C:\Win\System32'
        $env:Path | Should -Not -Be 'x'
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
    It 'retries with simpler SQL when the client reports class not registered, and remembers the level' {
        Set-TestBackend -Drives @(@{ Drive = 'T:'; Unc = '\\fs01\daten' }) -Rows @{ fs01 = @(@{ 'System.ItemUrl' = 'file://fs01/daten/a.txt'; 'System.FileName' = 'a.txt' }) }
        & $script:Mod {
            $script:InnerExecutor = $script:QueryExecutor
            $script:QueryExecutor = {
                param($m, $sql, $t)
                if ($sql -match 'System\.Kind,|ORDER BY System\.Search\.Rank') {
                    [void]$script:TestSql.Add(@{ Machine = $m; Sql = $sql })
                    throw [Management.Automation.MethodInvocationException]::new('Exception calling "Open"', [Runtime.InteropServices.COMException]::new('Klasse nicht registriert', [int]0x80040154))
                }
                & $script:InnerExecutor $m $sql $t
            }
        }
        $r = Search-Wss -Arguments @{ query = 'a' } -Config (New-TestConfig)
        $r.result_count | Should -Be 1
        $r.results[0].drive_path | Should -Be 'T:\a.txt'
        @(Get-TestSql).Count | Should -Be 3
        (Get-TestSql)[2].Sql | Should -Match 'ORDER BY System\.DateModified DESC$'
        $null = Search-Wss -Arguments @{ query = 'b' } -Config (New-TestConfig)
        @(Get-TestSql).Count | Should -Be 4
    }
    It 'does not retry other errors' {
        Set-TestBackend -Drives @(@{ Drive = 'Z:'; Unc = '\\fs01\p' }) -Errors @{ fs01 = 'boom 0x80070005' }
        { Search-Wss -Arguments @{ query = 'x' } -Config (New-TestConfig) } | Should -Throw '*permission problem*'
        @(Get-TestSql).Count | Should -Be 1
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
        (Get-TestSql)[0].Sql | Should -Match '^SELECT TOP 26 ' -Because '(limit+1)*3+20 rows are examined so blocked files do not crowd out allowed ones (+1 tells whether there is a next page)'
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
    It 'rejects binary files without readable text' {
        $p = Join-Path $Dir 'b.bin'
        [IO.File]::WriteAllBytes($p, [byte[]](1, 0, 2, 3))
        # Elsewhere: "looks like a binary file"; on Windows the filter finds no filter or no text.
        { Get-WssDocumentText $p } | Should -Throw '*copy_file*'
        { Get-WssDocumentText $p -Config @{ UseIFilter = $false } } | Should -Throw '*binary*'
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
    It 'keeps xlsx columns when cells are empty, with row numbers' {
        $p = Join-Path $Dir 'sparse.xlsx'
        New-Zip $p @{
            'xl/sharedStrings.xml'     = '<sst><si><t>Name</t></si><si><r><t>To</t></r><r><t>tal</t></r></si><si/><si><t>Q3</t></si></sst>'
            'xl/worksheets/sheet1.xml' = '<worksheet><sheetData><row r="1"><c r="A1" t="s"><v>0</v></c><c r="C1" t="s"><v>1</v></c><c r="D1" t="s"><v>3</v></c></row><row r="3"/><row r="5"><c r="A5" t="inlineStr"><is><t>Bob</t></is></c><c r="D5"><v>42</v></c></row></sheetData></worksheet>'
        }
        $lines = @((Get-WssDocumentText $p) -split "`n")
        $lines[1] | Should -Be "1`tName`t`tTotal`tQ3"
        $lines[2] | Should -Be "5`tBob`t`t`t42" -Because 'an empty self-closing row must not swallow the next row, and D5 stays in column D'
        $lines.Count | Should -Be 3
    }
    It 'uses real sheet names in workbook order and formats dates, percentages and booleans' {
        $p = Join-Path $Dir 'named.xlsx'
        New-Zip $p @{
            'xl/workbook.xml'            = '<workbook xmlns:r="r"><workbookPr/><sheets><sheet name="Q&amp;A" sheetId="5" r:id="rId9"/><sheet name="Data" sheetId="1" r:id="rId1" state="hidden"/></sheets></workbook>'
            'xl/_rels/workbook.xml.rels' = '<Relationships><Relationship Id="rId1" Target="worksheets/sheet1.xml"/><Relationship Id="rId9" Target="/xl/worksheets/sheet2.xml"/><Relationship Id="rId3" Target="styles.xml"/></Relationships>'
            'xl/styles.xml'              = '<styleSheet><numFmts><numFmt numFmtId="164" formatCode="dd/mm/yyyy\ hh:mm"/><numFmt numFmtId="165" formatCode="#,##0.00 &quot;EUR&quot;"/><numFmt numFmtId="166" formatCode="[h]:mm"/></numFmts><cellXfs><xf numFmtId="0"/><xf numFmtId="14"/><xf numFmtId="164"/><xf numFmtId="10"/><xf numFmtId="165"/><xf numFmtId="166"/></cellXfs></styleSheet>'
            'xl/worksheets/sheet1.xml'   = '<worksheet><dimension ref="A1:B1"/><sheetData><row r="1"><c r="A1"><v>1</v></c><c r="B1" t="b"><v>1</v></c></row></sheetData></worksheet>'
            'xl/worksheets/sheet2.xml'   = '<worksheet><sheetData><row r="1"><c r="A1" s="1"><v>45292</v></c><c r="B1" s="2"><v>45292.5</v></c><c r="C1" s="3"><v>0.125</v></c><c r="D1" s="4"><v>1234.5</v></c><c r="E1" s="5"><v>1.5</v></c><c r="F1" t="str"><f>A1</f><v>x</v></c></row></sheetData></worksheet>'
        }
        $text = Get-WssDocumentText $p
        $text.IndexOf('--- Sheet: Q&A ---') | Should -BeLessThan $text.IndexOf('--- Sheet: Data (hidden) [A1:B1] ---')
        $text | Should -Match ([regex]::Escape("1`t2024-01-01`t2024-01-01 12:00:00`t12.5%`t1234.5`t36:00:00`tx"))
        $text | Should -Match "1`t1`tTRUE"
    }
    It 'converts 1904-based workbook dates' {
        $p = Join-Path $Dir 'mac.xlsx'
        New-Zip $p @{
            'xl/workbook.xml'            = '<workbook><workbookPr date1904="1"/><sheets><sheet name="S" r:id="rId1"/></sheets></workbook>'
            'xl/_rels/workbook.xml.rels' = '<Relationships><Relationship Id="rId1" Target="worksheets/sheet1.xml"/></Relationships>'
            'xl/styles.xml'              = '<styleSheet><cellXfs><xf numFmtId="0"/><xf numFmtId="14"/></cellXfs></styleSheet>'
            'xl/worksheets/sheet1.xml'   = '<worksheet><sheetData><row r="1"><c r="A1" s="1"><v>0</v></c></row></sheetData></worksheet>'
        }
        Get-WssDocumentText $p | Should -Match "1`t1904-01-01"
    }
    It 'reads docx tables, headers, footnotes and comments but not deleted text or field codes' {
        $p = Join-Path $Dir 'full.docx'
        $cell = { param($t) "<w:tc><w:p><w:r><w:t>$t</w:t></w:r></w:p></w:tc>" }
        New-Zip $p @{
            'word/document.xml'  = '<w:document><w:body><w:p><w:r><w:t>Intro</w:t></w:r><w:del><w:r><w:delText>gone</w:delText></w:r></w:del><w:r><w:instrText> TOC \o </w:instrText></w:r></w:p>' +
                '<w:tbl><w:tr>' + (& $cell 'A') + '<w:tc><w:p><w:r><w:t>B1</w:t></w:r></w:p><w:p><w:r><w:t>B2</w:t></w:r></w:p></w:tc></w:tr><w:tr>' + (& $cell '1') + (& $cell '2') + '</w:tr></w:tbl>' +
                '<w:p><w:r><w:t>After</w:t></w:r></w:p></w:body></w:document>'
            'word/header1.xml'   = '<w:hdr><w:p><w:r><w:t>Confidential</w:t></w:r></w:p></w:hdr>'
            'word/header2.xml'   = '<w:hdr><w:p><w:r><w:t>Confidential</w:t></w:r></w:p></w:hdr>'
            'word/footnotes.xml' = '<w:footnotes><w:footnote w:type="separator" w:id="-1"><w:p><w:r><w:t>SEP</w:t></w:r></w:p></w:footnote><w:footnote w:id="1"><w:p><w:r><w:t>See annex.</w:t></w:r></w:p></w:footnote></w:footnotes>'
            'word/comments.xml'  = '<w:comments><w:comment w:id="0" w:author="Ann &amp; Co"><w:p><w:r><w:t>Check this</w:t></w:r></w:p></w:comment></w:comments>'
        }
        $text = Get-WssDocumentText $p
        $text | Should -Match "Intro`nA`tB1 B2`n1`t2`nAfter"
        $text | Should -Not -Match 'gone|TOC|SEP'
        ([regex]::Matches($text, 'Confidential')).Count | Should -Be 1
        $text | Should -Match '--- header: Confidential'
        $text | Should -Match '\[1\] See annex\.'
        $text | Should -Match 'Ann & Co: Check this'
    }
    It 'keeps text after a deleted paragraph mark' {
        $p = Join-Path $Dir 'tracked.docx'
        New-Zip $p @{ 'word/document.xml' = '<w:document><w:body><w:p><w:pPr><w:rPr><w:del w:id="1" w:author="A"/></w:rPr></w:pPr><w:r><w:t>Kept one</w:t></w:r></w:p><w:p><w:r><w:t>Kept two</w:t></w:r><w:del w:id="2"><w:r><w:delText>gone</w:delText></w:r></w:del></w:p></w:body></w:document>' }
        Get-WssDocumentText $p | Should -Be "Kept one`nKept two"
    }
    It 'reads pptx slides in presentation order with speaker notes' {
        $p = Join-Path $Dir 'ordered.pptx'
        New-Zip $p @{
            'ppt/presentation.xml'              = '<p:presentation><p:sldIdLst><p:sldId id="256" r:id="rId3"/><p:sldId id="257" r:id="rId2"/></p:sldIdLst></p:presentation>'
            'ppt/_rels/presentation.xml.rels'   = '<Relationships><Relationship Id="rId2" Target="slides/slide1.xml"/><Relationship Id="rId3" Target="slides/slide2.xml"/></Relationships>'
            'ppt/slides/slide1.xml'             = '<p:sld><a:p><a:r><a:t>Moved last</a:t></a:r></a:p></p:sld>'
            'ppt/slides/slide2.xml'             = '<p:sld><a:p><a:r><a:t>Opening</a:t></a:r></a:p></p:sld>'
            'ppt/slides/_rels/slide2.xml.rels'  = '<Relationships><Relationship Id="rId1" Target="../notesSlides/notesSlide7.xml"/></Relationships>'
            'ppt/notesSlides/notesSlide7.xml'   = '<p:notes><p:sp><p:nvSpPr><p:nvPr><p:ph type="sldImg"/></p:nvPr></p:nvSpPr></p:sp><p:sp><p:nvSpPr><p:nvPr><p:ph type="body" idx="1"/></p:nvPr></p:nvSpPr><p:txBody><a:p><a:r><a:t>Say hello</a:t></a:r></a:p></p:txBody></p:sp><p:sp><p:nvSpPr><p:nvPr><p:ph type="sldNum"/></p:nvPr></p:nvSpPr><p:txBody><a:p><a:r><a:t>1</a:t></a:r></a:p></p:txBody></p:sp></p:notes>'
        }
        $text = Get-WssDocumentText $p
        $text | Should -Match "--- Slide 1 ---`nOpening`nNotes: Say hello`n--- Slide 2 ---`nMoved last"
    }
    It 'reports damaged Office files clearly' {
        $p = Join-Path $Dir 'broken.docx'
        [IO.File]::WriteAllText($p, 'not a zip')
        { Get-WssDocumentText $p } | Should -Throw '*not a valid Office document*'
    }
    Context 'Windows filters' {
        AfterEach { & $script:Mod { $script:IFilterExtractor = $null } }
        It 'reads binary formats through the Windows filter' {
            $p = Join-Path $Dir 'scan.pdf'
            [IO.File]::WriteAllText($p, "%PDF-1.7`nbinary-ish but no NUL bytes")
            & $script:Mod { $script:IFilterExtractor = { param($Path, $Max, $Ms) $script:FilterCall = @($Path, $Max, $Ms); @{ Text = "Page one`nPage two"; NoFilter = $false; HResult = 0; Truncated = $false } } }
            Get-WssDocumentText $p -Config @{ FilterTimeout = 7 } | Should -Be "Page one`nPage two"
            $call = & $script:Mod { $script:FilterCall }
            $call[0] | Should -Be $p
            $call[2] | Should -Be 7000
        }
        It 'explains a missing filter, an empty text layer and a disabled filter' {
            $p = Join-Path $Dir 'old.doc'
            [IO.File]::WriteAllBytes($p, [byte[]](0xD0, 0xCF, 0x11, 0, 1))
            & $script:Mod { $script:IFilterExtractor = { @{ Text = $null; NoFilter = $true; HResult = -2147221164; Truncated = $false } } }
            { Get-WssDocumentText $p } | Should -Throw '*No Windows filter (IFilter) for .doc files*copy_file*'
            & $script:Mod { $script:IFilterExtractor = { @{ Text = "  `n "; NoFilter = $false; HResult = 0; Truncated = $false } } }
            { Get-WssDocumentText $p } | Should -Throw '*No text found*scanned*'
            { Get-WssDocumentText $p -Config @{ UseIFilter = $false } } | Should -Throw '*disabled (useIFilter)*'
        }
        It 'marks truncated filter output' {
            $p = Join-Path $Dir 'big.msg'
            [IO.File]::WriteAllBytes($p, [byte[]](1, 0, 2))
            & $script:Mod { $script:IFilterExtractor = { @{ Text = 'abc'; NoFilter = $false; HResult = 0; Truncated = $true } } }
            Get-WssDocumentText $p | Should -Match '^abc\n\[\.\.\. text truncated'
        }
        It 'prefers the filter for RTF and falls back to the raw text without one' {
            $p = Join-Path $Dir 'memo.rtf'
            [IO.File]::WriteAllText($p, '{\rtf1\ansi Hello}')
            & $script:Mod { $script:IFilterExtractor = { @{ Text = 'Hello'; NoFilter = $false; HResult = 0; Truncated = $false } } }
            Get-WssDocumentText $p | Should -Be 'Hello'
            & $script:Mod { $script:IFilterExtractor = { @{ Text = $null; NoFilter = $true; HResult = 0; Truncated = $false } } }
            Get-WssDocumentText $p | Should -Be '{\rtf1\ansi Hello}'
        }
        It 'compiles the filter interop code' -Skip:(-not ($PSVersionTable.PSVersion.Major -lt 6 -or $IsWindows)) {
            # Only Windows has query.dll; compiling checks the C# also builds with the .NET Framework compiler (5.1).
            & $script:Mod { Add-Type -TypeDefinition $script:IFilterSource -Language CSharp; $script:IFilterLoaded = $true }
            ([type]'WssIFilter.Extractor') | Should -Not -BeNullOrEmpty
        }
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
    It 'user policy (gitignore, every share) semantics: <pattern> vs <path> -> <expected>' -TestCases @(
        @{ pattern = 'secret'; path = '\\fs01\data\secret\x.txt'; expected = $true }
        @{ pattern = 'secret'; path = '\\fs02\other\a\b\secret'; expected = $true }
        @{ pattern = 'secret'; path = '\\fs01\secret\x.txt'; expected = $false }
        @{ pattern = '/HR'; path = '\\fs02\other\HR\x.txt'; expected = $true }
        @{ pattern = '/HR'; path = '\\fs02\other\a\HR\x.txt'; expected = $false }
        @{ pattern = 'a/secret'; path = '\\fs01\data\a\secret\x'; expected = $true }
        @{ pattern = 'a/secret'; path = '\\fs01\data\b\a\secret\x'; expected = $false }
        @{ pattern = '*.kdbx'; path = '\\fs01\data\x\vault.KDBX'; expected = $true }
        @{ pattern = '\\fs01\data\*\Contracts'; path = '\\fs01\data\P\Contracts\c.pdf'; expected = $true }
        @{ pattern = '//fs01/data/finance'; path = '\\fs01\data\Finance\q1.xlsx'; expected = $true }
        @{ pattern = 'Z:\Finance'; path = '\\fs01\data\finance\q1.xlsx'; expected = $true }
    ) {
        $t = @(@{ Name = 'fs01'; Machine = 'fs01'; Shares = @(@{ Name = 'data'; Unc = '\\fs01\data'; Drives = @('Z:') }) })
        $rule = New-WssPolicyRule -Pattern $pattern -Source 'test' -Targets $t -AnyShare
        $rule.Regex.IsMatch((Get-WssCanonicalUnc $path)) | Should -Be $expected
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
    It 'applies the user .claude-policy to every share' {
        $f = Join-Path ([IO.Path]::GetTempPath()) "wss-userpol-$([guid]::NewGuid())"
        Set-Content -LiteralPath $f -Value "# mine`nPersonal/`n/HR`n!keep`nQ:\nope"
        try {
            Set-TestBackend -Drives @(@{ Drive = 'Z:'; Unc = '\\fs01\data' }, @{ Drive = 'Y:'; Unc = '\\fs02\team' })
            $cfg = New-TestConfig; $cfg.PolicyFile = $f
            $p = Get-WssPolicy -Config $cfg -Targets @(Get-WssTargets -Config $cfg)
            $p.Counts['user-policy'] | Should -Be 2
            @($p.Warnings).Count | Should -Be 2
            ($p.PolicyFiles | Where-Object { $_.file -eq $f }).rules | Should -Be 2
            (Test-WssBlocked '\\fs01\data\a\Personal\x.txt' $p).Source | Should -Be 'user-policy'
            (Test-WssBlocked '\\fs02\team\HR\x.txt' $p).Source | Should -Be 'user-policy'
            Test-WssBlocked '\\fs02\team\a\HR\x.txt' $p | Should -BeNullOrEmpty
        } finally { Remove-Item -LiteralPath $f -ErrorAction SilentlyContinue }
    }
    It 'fails closed when the user .claude-policy is invalid' {
        $f = Join-Path ([IO.Path]::GetTempPath()) "wss-userpol-$([guid]::NewGuid())"
        Set-Content -LiteralPath $f -Value "bad|line"
        try {
            Set-TestBackend -Drives @(@{ Drive = 'Z:'; Unc = '\\fs01\data' })
            $cfg = New-TestConfig; $cfg.PolicyFile = $f
            $p = Get-WssPolicy -Config $cfg -Targets @(Get-WssTargets -Config $cfg)
            @($p.BlockedShares).Count | Should -Be 1
            (Test-WssBlocked '\\fs01\data\a.txt' $p).Source | Should -Be 'user-policy-error'
        } finally { Remove-Item -LiteralPath $f -ErrorAction SilentlyContinue }
    }
    It 'creates an empty user .claude-policy once and never overwrites it' {
        $dir = Join-Path ([IO.Path]::GetTempPath()) "wss-init-$([guid]::NewGuid())"
        $cfg = New-TestConfig; $cfg.PolicyFile = Join-Path $dir '.claude-policy'
        try {
            Initialize-WssUserPolicy -Config $cfg | Should -BeTrue
            (ConvertFrom-WssPolicyText (Get-Content -LiteralPath $cfg.PolicyFile -Raw)).Patterns.Count | Should -Be 0
            Set-Content -LiteralPath $cfg.PolicyFile -Value 'mine'
            Initialize-WssUserPolicy -Config $cfg | Should -BeFalse
            (Get-Content -LiteralPath $cfg.PolicyFile -Raw).Trim() | Should -Be 'mine'
        } finally { Remove-Item -LiteralPath $dir -Recurse -ErrorAction SilentlyContinue }
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
        for ($i = 0; $i -lt 26; $i++) { $rows += @{ 'System.ItemUrl' = "file://fs01/data/secret/$i.txt"; 'System.FileName' = "$i.txt" } }
        Set-TestBackend -Drives @(@{ Drive = 'Z:'; Unc = '\\fs01\data' }) -Rows @{ fs01 = $rows } -Policies @{ '\\fs01\data' = @{ Status = 'ok'; Content = 'secret' } }
        $r = Search-Wss -Arguments @{ query = 'x'; max_results = 1 } -Config (New-TestConfig)
        @(Get-TestSql).Count | Should -Be 2
        (Get-TestSql)[1].Sql | Should -Match '^SELECT TOP 104 '
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
        $r.result.protocolVersion | Should -Be '2025-11-25'
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

Describe 'Find-WssPassages' {
    BeforeAll {
        $script:Doc = (@(1..30 | ForEach-Object { "line $_" }) + @('The penalty', 'clause applies.', 'x', 'y', 'z', 'Another PENALTY CLAUSE here.')) -join "`n"
    }
    It 'returns the matching lines with context, ignoring case and line breaks' {
        $r = Find-WssPassages -Text $Doc -Find 'penalty clause' -Context 1
        $r.MatchCount | Should -Be 2
        $r.Passages.Count | Should -Be 2
        $r.Passages[0].line | Should -Be 30
        $r.Passages[0].text | Should -Be "line 30`nThe penalty`nclause applies.`nx"
        $Doc.Substring($r.Passages[0].offset).StartsWith('line 30') | Should -BeTrue -Because 'offset can be passed to read_file'
        $r.Passages[1].text | Should -Be "z`nAnother PENALTY CLAUSE here."
    }
    It 'merges overlapping passages and limits their number' {
        $r = Find-WssPassages -Text $Doc -Find 'line 1 OR line 2' -Context 0 -MaxPassages 3
        $r.MatchCount | Should -Be 22 -Because '"line 1" matches lines 1 and 10-19, "line 2" lines 2 and 20-29'
        $r.Passages.Count | Should -Be 2 -Because 'adjacent lines merge: lines 1-2 and lines 10-29'
        $r.Passages[0].text | Should -Be "line 1`nline 2"
        $r.Passages[1].line | Should -Be 10
        $r.Passages[1].text | Should -Match '^line 10\n(.|\n)*line 29$'
        $r2 = Find-WssPassages -Text $Doc -Find 'line 5 OR line 25' -Context 0 -MaxPassages 1
        $r2.Passages.Count | Should -Be 1
        $r2.Truncated | Should -BeTrue
    }
    It 'cuts very long lines around the match' {
        $long = ('a' * 5000) + ' needle ' + ('b' * 5000)
        $r = Find-WssPassages -Text $long -Find 'needle'
        $r.Passages[0].text.Length | Should -BeLessThan 1600
        $r.Passages[0].text | Should -Match '^\u2026a+ needle b+\u2026$'
    }
    It 'handles Windows line endings' {
        $r = Find-WssPassages -Text "a`r`nthe cap`r`nb`r`n" -Find 'cap' -Context 1
        $r.Passages[0].text | Should -Be "a`nthe cap`nb"
        $r.Passages[0].line | Should -Be 1
    }
    It 'treats the search text literally' {
        (Find-WssPassages -Text 'cost (EUR) 5' -Find '(EUR)').MatchCount | Should -Be 1
        (Find-WssPassages -Text 'abc' -Find 'a.c').MatchCount | Should -Be 0
        { Find-WssPassages -Text 'abc' -Find '  ' } | Should -Throw '*word or phrase*'
    }
}

Describe 'Search snippets and paging' {
    BeforeAll {
        $script:SnipDir = Join-Path ([IO.Path]::GetTempPath()) "wss-snip-$([guid]::NewGuid())"
        New-Item -ItemType Directory -Path $SnipDir | Out-Null
        [IO.File]::WriteAllText((Join-Path $SnipDir 'a.txt'), ('filler ' * 50) + 'the Budgets for 2024 are final ' + ('tail ' * 60))
        [IO.File]::WriteAllText((Join-Path $SnipDir 'b.txt'), 'nothing relevant')
        [IO.File]::WriteAllText((Join-Path $SnipDir 'c.jpg'), 'budget')
    }
    AfterAll { Remove-Item $SnipDir -Recurse -Force -ErrorAction SilentlyContinue }
    It 'adds text around the first match and skips files without one' {
        # Local test files: on Windows the symlink check would refuse paths that are not on a share.
        Mock -ModuleName WindowsServerSearch Get-WssFinalPath { $null }
        $results = @(
            [ordered]@{ name = 'a.txt'; path = (Join-Path $SnipDir 'a.txt') },
            [ordered]@{ name = 'b.txt'; path = (Join-Path $SnipDir 'b.txt') },
            [ordered]@{ name = 'c.jpg'; path = (Join-Path $SnipDir 'c.jpg') }
        )
        $n = Add-WssSnippets -Results $results -Query 'budget -draft' -Config @{} -Targets @() -Policy @{ Rules = @() }
        $n | Should -Be 1
        $results[0].snippet | Should -Match '^\u2026.*the Budgets for 2024 are final.*\u2026$'
        $results[0].snippet | Should -Not -Match '\s{2}'
        $results[1].Contains('snippet') | Should -BeFalse
        $results[2].Contains('snippet') | Should -BeFalse -Because 'images are not read'
    }
    It 'pages through merged results with offset and next_offset' {
        $rows = @{}
        foreach ($srv in 'fs01', 'fs02') {
            $rows[$srv] = @(1..3 | ForEach-Object { @{ 'System.ItemUrl' = "file://$srv/s/$_.txt"; 'System.FileName' = "$srv-$_.txt"; 'System.Search.Rank' = $(if ($srv -eq 'fs01') { 100 * $_ } else { 100 * $_ + 50 }) } })
        }
        Set-TestBackend -Drives @(@{ Drive = 'Y:'; Unc = '\\fs01\s' }, @{ Drive = 'Z:'; Unc = '\\fs02\s' }) -Rows $rows
        $p1 = Search-Wss -Arguments @{ query = 'x'; max_results = 4 } -Config (New-TestConfig)
        @($p1.results.name) | Should -Be @('fs02-3.txt', 'fs01-3.txt', 'fs02-2.txt', 'fs01-2.txt')
        $p1.next_offset | Should -Be 4
        $p2 = Search-Wss -Arguments @{ query = 'x'; max_results = 4; offset = 4 } -Config (New-TestConfig)
        @($p2.results.name) | Should -Be @('fs02-1.txt', 'fs01-1.txt')
        $p2.offset | Should -Be 4
        $p2.Contains('next_offset') | Should -BeFalse
        (Get-TestSql)[-1].Sql | Should -Match '^SELECT TOP 47 ' -Because '(offset+limit+1)*3+20'
    }
}

Describe 'Discovery cache' {
    BeforeEach {
        Set-TestBackend -Drives @(@{ Drive = 'Z:'; Unc = '\\fs01\p' })
        & $script:Mod { $script:DriveCalls = 0; $script:DriveProvider = { $script:DriveCalls++; $script:TestDrives } }
    }
    It 'reuses discovered servers within the TTL and rediscovers on refresh or other settings' {
        $cfg = (New-TestConfig) + @{ DiscoveryTtl = 60 }
        $null = Get-WssTargets -Config $cfg
        $t = @(Get-WssTargets -Config $cfg)
        $t[0].Name | Should -Be 'fs01'
        (& $script:Mod { $script:DriveCalls }) | Should -Be 1
        $null = Get-WssTargets -Config $cfg -Refresh
        (& $script:Mod { $script:DriveCalls }) | Should -Be 2
        $null = Get-WssTargets -Config ((New-TestConfig -Exclude @('fs09')) + @{ DiscoveryTtl = 60 })
        (& $script:Mod { $script:DriveCalls }) | Should -Be 3
    }
    It 'does not cache with a TTL of 0' {
        $cfg = (New-TestConfig) + @{ DiscoveryTtl = 0 }
        $null = Get-WssTargets -Config $cfg
        $null = Get-WssTargets -Config $cfg
        (& $script:Mod { $script:DriveCalls }) | Should -Be 2
    }
}

Describe 'Date filters' {
    It 'treats plain dates as local days and includes the whole modified_before day' {
        $start = [DateTime]::SpecifyKind([datetime]'2024-03-10', 'Local').ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')
        $end = [DateTime]::SpecifyKind([datetime]'2024-03-10T23:59:59', 'Local').ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')
        Format-WssSqlDate '2024-03-10' 'x' | Should -Be "'$start'"
        Format-WssSqlDate '2024-03-10' 'x' -EndOfDay | Should -Be "'$end'"
        New-WssSearchSql -Machine 'm' -ModifiedBefore '2024-03-10' | Should -Match ([regex]::Escape("System.DateModified <= '$end'"))
    }
    It 'treats times without offset as local and honours Z and offsets' {
        $local = [DateTime]::SpecifyKind([datetime]'2024-03-10T08:30:00', 'Local').ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')
        Format-WssSqlDate '2024-03-10T08:30' 'x' | Should -Be "'$local'"
        Format-WssSqlDate '2024-03-10T08:30:00Z' 'x' | Should -Be "'2024-03-10 08:30:00'"
        Format-WssSqlDate '2024-03-10T08:30:00+02:00' 'x' | Should -Be "'2024-03-10 06:30:00'"
        Format-WssSqlDate '2024-03-10' 'x' -EndOfDay:$false | Should -Not -Match '23:59'
    }
}

Describe 'Structured tool output' {
    AfterEach { & $script:Mod { $script:ProtocolVersion = $null } }
    It 'declares output schemas and returns structuredContent from protocol 2025-06-18' {
        $null = Invoke-WssMessageLine '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}'
        $tools = (Invoke-WssMessageLine '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | ConvertFrom-Json).result.tools
        foreach ($t in $tools) { $t.outputSchema.type | Should -Be 'object' -Because $t.name }
        Set-TestBackend -Drives @(@{ Drive = 'Z:'; Unc = '\\fs01\p' })
        $r = (Invoke-WssMessageLine '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_servers","arguments":{}}}' | ConvertFrom-Json).result
        $r.structuredContent.servers[0].name | Should -Be 'fs01'
        ($r.content[0].text | ConvertFrom-Json).servers[0].name | Should -Be 'fs01'
    }
    It 'search results match the declared schema' {
        $null = Invoke-WssMessageLine '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25"}}'
        Set-TestBackend -Drives @(@{ Drive = 'Z:'; Unc = '\\fs01\p' }) -Rows @{ fs01 = @(@{ 'System.ItemUrl' = 'file://fs01/p/a.txt'; 'System.FileName' = 'a.txt'; 'System.Size' = 3; 'System.Search.Rank' = 1 }) }
        $r = (Invoke-WssMessageLine '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"search_files","arguments":{"query":"a"}}}' | ConvertFrom-Json).result
        $schema = (& $script:Mod { Get-WssOutputSchemas }).search_files
        foreach ($req in $schema.required) { $r.structuredContent.PSObject.Properties.Name | Should -Contain $req }
        $r.structuredContent.result_count | Should -BeOfType [long]
        @($r.structuredContent.results).Count | Should -Be 1
        $r.structuredContent.results[0].drive_path | Should -Be 'Z:\a.txt'
    }
    It 'keeps the old result format for older protocol versions' {
        $null = Invoke-WssMessageLine '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26"}}'
        $tools = (Invoke-WssMessageLine '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | ConvertFrom-Json).result.tools
        $tools[0].PSObject.Properties.Name | Should -Not -Contain 'outputSchema'
        Set-TestBackend -Drives @(@{ Drive = 'Z:'; Unc = '\\fs01\p' })
        $r = (Invoke-WssMessageLine '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_servers","arguments":{}}}' | ConvertFrom-Json).result
        $r.PSObject.Properties.Name | Should -Not -Contain 'structuredContent'
    }
}
