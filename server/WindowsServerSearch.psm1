# WindowsServerSearch.psm1
# Core logic for the Windows Server Search MCP server.
# Compatible with Windows PowerShell 5.1 and PowerShell 7+ (no external modules).


$script:ServerName = 'windows-server-search'
$script:ServerVersion = '0.0.0-dev'
$script:SupportedProtocolVersions = @('2025-11-25', '2025-06-18', '2025-03-26', '2024-11-05')
$script:ProtocolVersion = $null   # negotiated in initialize

# Pluggable backends. Tests (and WSS_FAKE_BACKEND) replace these.
$script:QueryExecutor = $null      # scriptblock: param($Machine, $Sql, $TimeoutSeconds) -> array of hashtables
$script:DriveProvider = $null      # scriptblock: -> array of @{ Drive='Z:'; Unc='\\srv\share' }
$script:ShareProvider = $null      # scriptblock: param($HostName) -> array of share names

$script:ResultColumns = @(
    'System.ItemUrl',
    'System.ItemPathDisplay',
    'System.FileName',
    'System.ItemTypeText',
    'System.Size',
    'System.DateModified',
    'System.DateCreated',
    'System.Author',
    'System.Title',
    'System.Kind',
    'System.Search.Rank'
)
# Fallback for clients that fail with "class not registered" on some servers: only basic columns.
$script:BasicColumns = @(
    'System.ItemUrl',
    'System.ItemPathDisplay',
    'System.FileName',
    'System.Size',
    'System.DateModified'
)
$script:MaxCompatLevel = 3
$script:CompatLevel = @{}

# ---------------------------------------------------------------------------
# Logging (stderr only - stdout is reserved for JSON-RPC)
# ---------------------------------------------------------------------------

function Write-WssLog {
    param([string]$Message)
    if ($env:WSS_LOG_LEVEL -eq 'silent') { return }
    try { [Console]::Error.WriteLine("[$script:ServerName] $Message") } catch { }
}

function Set-WssVersion {
    param([string]$Version)
    if ($Version) { $script:ServerVersion = $Version }
}

function Test-WssIsWindows {
    if ($PSVersionTable.PSVersion.Major -lt 6) { return $true }
    return [bool]$IsWindows
}

# ---------------------------------------------------------------------------
# Process environment
# ---------------------------------------------------------------------------

$script:RestoredEnv = @()

function Get-WssDefaultEnvironment {
    <# The variables a normal logon session has: system folders, machine, user and volatile environment. #>
    $envs = [ordered]@{}
    $folders = [ordered]@{
        'windir'            = 'Windows'
        'SystemRoot'        = 'Windows'
        'ProgramData'       = 'CommonApplicationData'
        'ALLUSERSPROFILE'   = 'CommonApplicationData'
        'CommonProgramFiles' = 'CommonProgramFiles'
        'ProgramFiles'      = 'ProgramFiles'
    }
    foreach ($k in $folders.Keys) {
        $v = [Environment]::GetFolderPath($folders[$k])
        if ($v) { $envs[$k] = $v }
    }
    if ([Environment]::Is64BitOperatingSystem) {
        $x86 = [Environment]::GetFolderPath('ProgramFilesX86')
        $cx86 = [Environment]::GetFolderPath('CommonProgramFilesX86')
        if ($x86) { $envs['ProgramFiles(x86)'] = $x86 }
        if ($cx86) { $envs['CommonProgramFiles(x86)'] = $cx86 }
        try {
            $cv = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion' -ErrorAction Stop
            if ($cv.ProgramW6432Dir) { $envs['ProgramW6432'] = $cv.ProgramW6432Dir }
            if ($cv.CommonW6432Dir) { $envs['CommonProgramW6432'] = $cv.CommonW6432Dir }
        } catch { }
    }
    $envs['COMPUTERNAME'] = [Environment]::MachineName
    $envs['USERDOMAIN'] = [Environment]::UserDomainName
    foreach ($scope in 'Machine', 'User') {
        try {
            $vars = [Environment]::GetEnvironmentVariables($scope)
            foreach ($k in $vars.Keys) { $envs["$k"] = "$($vars[$k])" }
        } catch { }
    }
    try {
        $vol = Get-ItemProperty -LiteralPath 'HKCU:\Volatile Environment' -ErrorAction Stop
        foreach ($p in $vol.PSObject.Properties) {
            if ($p.Name -notlike 'PS*' -and $p.Value -is [string]) { $envs[$p.Name] = $p.Value }
        }
    } catch { }
    return $envs
}

function Restore-WssEnvironment {
    <# MCP hosts often start servers with a reduced environment (only PATH, SYSTEMROOT, USERPROFILE and a few
       more). COM components registered as %windir%\... or %CommonProgramFiles%\... then fail with "class not
       registered". Adds the missing logon variables; variables that are set are never changed. #>
    param([System.Collections.IDictionary]$Defaults)
    if (-not $PSBoundParameters.ContainsKey('Defaults')) {
        if (-not (Test-WssIsWindows)) { return @() }
        $Defaults = Get-WssDefaultEnvironment
    }
    $added = @()
    foreach ($k in @($Defaults.Keys)) {
        if ($k -ieq 'Path' -or [string]::IsNullOrEmpty("$($Defaults[$k])")) { continue }
        if ([string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable($k, 'Process'))) {
            [Environment]::SetEnvironmentVariable($k, "$($Defaults[$k])", 'Process')
            $added += $k
        }
    }
    foreach ($k in $added) {
        $v = [Environment]::GetEnvironmentVariable($k, 'Process')
        if ($v -match '%') { [Environment]::SetEnvironmentVariable($k, [Environment]::ExpandEnvironmentVariables($v), 'Process') }
    }
    $script:RestoredEnv = @($added)
    if ($added.Count -gt 0) { Write-WssLog "restored missing environment variables: $($added -join ', ')" }
    return $added
}

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

function ConvertTo-WssBool {
    param($Value, [bool]$Default)
    if ($null -eq $Value) { return $Default }
    $s = "$Value".Trim().ToLowerInvariant()
    if ($s -eq '') { return $Default }
    if ($s -in @('1', 'true', 'yes', 'on', 'y')) { return $true }
    if ($s -in @('0', 'false', 'no', 'off', 'n')) { return $false }
    return $Default
}

function ConvertTo-WssInt {
    param($Value, [int]$Default, [int]$Min = 1, [int]$Max = [int]::MaxValue)
    $n = 0
    if ($null -eq $Value -or -not [int]::TryParse("$Value".Trim(), [ref]$n)) { return $Default }
    if ($n -lt $Min) { return $Min }
    if ($n -gt $Max) { return $Max }
    return $n
}

function Split-WssList {
    param([string]$Value, [string]$Separators = '[;,\r\n]+')
    if (-not $Value) { return @() }
    return @($Value -split $Separators | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Get-WssConfig {
    <#
      Reads configuration from environment variables (set by the plugin's userConfig)
      and an optional JSON config file. List settings (servers, exclude, deny) are merged;
      for single values the config file wins, because Cowork has no UI for plugin options
      and always passes the plugin defaults - the file is how Cowork users change them.
        WSS_SERVERS          ; or , separated UNC roots, e.g. \\fs01\projects;\\fs02
        WSS_AUTO_DISCOVER    true|false (default true) - use mapped network drives
        WSS_EXCLUDE          ; separated server names or UNC roots to ignore
        WSS_MAX_RESULTS      default result limit (default 50, max 500)
        WSS_QUERY_TIMEOUT    seconds per index query (default 30)
        WSS_USE_NETBIOS      true|false (default true) - query FQDN hosts by short name
        WSS_DENY             ; or newline separated deny patterns (wildcards), e.g. \\fs01\hr\**;**\Personal
                             (Cowork: use the .claude-policy file next to the config file instead)
        WSS_POLICY_TTL       seconds to cache share .claude-policy files (default 300)
        WSS_DOWNLOAD_DIR     default local folder for copy_file
        WSS_MAX_COPY_MB      maximum size per copied file in MB (default 500)
        WSS_WRITE_ENABLED    true|false (default true) - save_file (write to servers)
        WSS_WRITE_OVERWRITE  true|false (default true) - allow overwriting (old version kept as backup)
        WSS_WRITE_MAX_MB     maximum size per written file in MB (default 100)
        WSS_WRITE_LOG        write log path (default %LOCALAPPDATA%\windows-server-search-mcp\write-log.jsonl)
        WSS_USE_IFILTER      true|false (default true) - read PDF, .doc, .rtf, .msg ... through Windows filters
        WSS_FILTER_TIMEOUT   seconds per Windows filter run (default 60)
        WSS_DISCOVERY_TTL    seconds to reuse discovered servers/shares between tool calls (default 60)
        WSS_CONFIG_FILE      path to JSON config file (default %APPDATA%\windows-server-search-mcp\config.json);
                             the user's .claude-policy file lives in the same folder
    #>
    $file = @{}
    $path = $env:WSS_CONFIG_FILE
    if (-not $path -and $env:APPDATA) {
        $path = [IO.Path]::Combine($env:APPDATA, 'windows-server-search-mcp', 'config.json')
    }
    if ($path -and (Test-Path -LiteralPath $path)) {
        try {
            $obj = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            foreach ($p in $obj.PSObject.Properties) { $file[$p.Name] = $p.Value }
            # Nested "write": { "enabled", "allowOverwrite", "maxMB", "logPath" }
            if ($file['write'] -is [System.Management.Automation.PSCustomObject]) {
                $map = @{ enabled = 'writeEnabled'; allowOverwrite = 'writeAllowOverwrite'; maxMB = 'writeMaxMB'; logPath = 'writeLogPath' }
                foreach ($p in $file['write'].PSObject.Properties) { if ($map.ContainsKey($p.Name)) { $file[$map[$p.Name]] = $p.Value } }
            }
        } catch {
            Write-WssLog "Ignoring unreadable config file '$path': $($_.Exception.Message)"
        }
    }

    function Get-EnvValue($envName) {
        $v = [Environment]::GetEnvironmentVariable($envName)
        # Ignore unresolved plugin placeholders such as ${user_config.servers}
        if ($null -ne $v -and "$v" -match '^\s*\$\{[^}]*\}\s*$') { $v = $null }
        if ($null -ne $v -and "$v".Trim() -ne '') { return "$v" }
        return $null
    }
    function Get-FileValue($fileKey) {
        if (-not $file.ContainsKey($fileKey) -or $null -eq $file[$fileKey]) { return $null }
        $fv = $file[$fileKey]
        if ($fv -is [array]) { return ($fv -join ';') }
        if ("$fv".Trim() -eq '') { return $null }
        return $fv
    }
    function Pick($envName, $fileKey) {
        # Single value: config file first, then plugin option / environment.
        $fv = Get-FileValue $fileKey
        if ($null -ne $fv) { return $fv }
        return (Get-EnvValue $envName)
    }
    function PickList($envName, $fileKey, $separators = '[;,\r\n]+') {
        # List: union of plugin option / environment and config file.
        $out = @()
        foreach ($x in @(Split-WssList (Get-EnvValue $envName) $separators) + @(Split-WssList (Get-FileValue $fileKey) $separators)) {
            if (-not ($out -contains $x)) { $out += $x }
        }
        return $out
    }

    return @{
        Servers        = @(PickList 'WSS_SERVERS' 'servers')
        AutoDiscover   = ConvertTo-WssBool (Pick 'WSS_AUTO_DISCOVER' 'autoDiscover') $true
        Exclude        = @(PickList 'WSS_EXCLUDE' 'exclude')
        MaxResults     = ConvertTo-WssInt (Pick 'WSS_MAX_RESULTS' 'maxResults') 50 1 500
        QueryTimeout   = ConvertTo-WssInt (Pick 'WSS_QUERY_TIMEOUT' 'queryTimeout') 30 1 600
        UseNetBios     = ConvertTo-WssBool (Pick 'WSS_USE_NETBIOS' 'useNetBios') $true
        Deny           = @(PickList 'WSS_DENY' 'deny' '[;\r\n]+')
        PolicyTtl      = ConvertTo-WssInt (Pick 'WSS_POLICY_TTL' 'policyTtl') 300 0 86400
        DownloadDir    = (Pick 'WSS_DOWNLOAD_DIR' 'downloadDir')
        MaxCopyMB      = ConvertTo-WssInt (Pick 'WSS_MAX_COPY_MB' 'maxCopyMB') 500 1 102400
        WriteEnabled   = ConvertTo-WssBool (Pick 'WSS_WRITE_ENABLED' 'writeEnabled') $true
        WriteAllowOverwrite = ConvertTo-WssBool (Pick 'WSS_WRITE_OVERWRITE' 'writeAllowOverwrite') $true
        WriteMaxMB     = ConvertTo-WssInt (Pick 'WSS_WRITE_MAX_MB' 'writeMaxMB') 100 1 102400
        WriteLogPath   = (Pick 'WSS_WRITE_LOG' 'writeLogPath')
        UseIFilter     = ConvertTo-WssBool (Pick 'WSS_USE_IFILTER' 'useIFilter') $true
        FilterTimeout  = ConvertTo-WssInt (Pick 'WSS_FILTER_TIMEOUT' 'filterTimeout') 60 1 600
        DiscoveryTtl   = ConvertTo-WssInt (Pick 'WSS_DISCOVERY_TTL' 'discoveryTtl') 60 0 3600
        ConfigFile     = $path
        PolicyFile     = $(if ($path) { [IO.Path]::Combine([IO.Path]::GetDirectoryName($path), $script:PolicyFileName) })
    }
}

# ---------------------------------------------------------------------------
# UNC / path helpers
# ---------------------------------------------------------------------------

function ConvertFrom-WssUncPath {
    <# Parses \\host\share\rest (or //host/share/rest, file://host/share/rest). Returns $null if not UNC. #>
    param([string]$Path)
    if (-not $Path) { return $null }
    $p = $Path.Trim()
    if ($p -match '^(?i)file:') {
        $p = $p -replace '^(?i)file:/*', '\\'
        try { $p = [Uri]::UnescapeDataString($p) } catch { }
    }
    $p = $p -replace '/', '\'
    if ($p -notmatch '^\\\\([^\\]+)(?:\\([^\\]+))?(?:\\(.*))?$') { return $null }
    $hostName = $Matches[1]
    $share = $null
    if ($Matches.Count -gt 2 -and $Matches[2]) { $share = $Matches[2] }
    $rest = ''
    if ($Matches.Count -gt 3 -and $Matches[3]) { $rest = $Matches[3].TrimEnd('\') }
    if ($hostName -in @('?', '.')) { return $null }  # \\?\C:\ and \\.\ device paths
    $root = "\\$hostName"
    if ($share) { $root = "\\$hostName\$share" }
    return @{ Host = $hostName; Share = $share; Rest = $rest; Root = $root }
}

function Get-WssQueryMachine {
    <# Windows Search remote queries want the NetBIOS name; use the first label of FQDNs. #>
    param([string]$HostName, [bool]$UseNetBios = $true)
    if (-not $UseNetBios) { return $HostName }
    if ($HostName -match '^\d{1,3}(\.\d{1,3}){3}$') { return $HostName }
    if ($HostName -match '^\[?[0-9a-fA-F:]+\]?$' -and $HostName.Contains(':')) { return $HostName }
    return ($HostName -split '\.')[0]
}

# ---------------------------------------------------------------------------
# Discovery
# ---------------------------------------------------------------------------

function Get-WssMappedDrives {
    <# Returns network drive mappings of the current user: @{ Drive='Z:'; Unc='\\srv\share' } #>
    if ($script:DriveProvider) { return @(& $script:DriveProvider) }
    if (-not (Test-WssIsWindows)) { return @() }

    $map = [ordered]@{}
    try {
        $disks = Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=4' -ErrorAction Stop
        foreach ($d in $disks) {
            if ($d.ProviderName -and $d.DeviceID) { $map[$d.DeviceID.ToUpperInvariant()] = $d.ProviderName }
        }
    } catch {
        Write-WssLog "CIM drive discovery failed: $($_.Exception.Message)"
    }
    # Persistent mappings (also covers drives that are currently disconnected)
    try {
        if (Test-Path 'HKCU:\Network') {
            foreach ($k in Get-ChildItem 'HKCU:\Network' -ErrorAction Stop) {
                $letter = ($k.PSChildName.ToUpperInvariant() + ':')
                $remote = (Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction Stop).RemotePath
                if ($remote -and -not $map.Contains($letter)) { $map[$letter] = $remote }
            }
        }
    } catch {
        Write-WssLog "Registry drive discovery failed: $($_.Exception.Message)"
    }
    # PSDrives (covers New-PSDrive -Persist / SMB mappings not visible to CIM in some sessions)
    try {
        foreach ($d in Get-PSDrive -PSProvider FileSystem -ErrorAction Stop) {
            if ($d.DisplayRoot -and $d.DisplayRoot.StartsWith('\\')) {
                $letter = ($d.Name.ToUpperInvariant() + ':')
                if (-not $map.Contains($letter)) { $map[$letter] = $d.DisplayRoot }
            }
        }
    } catch { }

    $out = @()
    foreach ($k in $map.Keys) { $out += @{ Drive = $k; Unc = $map[$k].TrimEnd('\') } }
    return $out
}

function ConvertFrom-WssNetView {
    <# Parses `net view \\server` output (any UI language) into share names. #>
    param([string[]]$Lines)
    $shares = @()
    $inTable = $false
    foreach ($line in $Lines) {
        if ($line -match '^-{5,}') { $inTable = $true; continue }
        if (-not $inTable) { continue }
        if ($line.Trim() -eq '') { continue }
        # Rows are fixed-width columns separated by 2+ spaces; the last line is a status message.
        $name = ($line -split '\s{2,}')[0].Trim()
        $cols = @($line -split '\s{2,}' | Where-Object { $_.Trim() })
        if ($cols.Count -lt 2) { continue }   # status / footer line
        if ($name.EndsWith('$')) { continue }
        $shares += $name
    }
    return $shares
}

function Get-WssServerShares {
    param([string]$HostName)
    if ($script:ShareProvider) { return @(& $script:ShareProvider $HostName) }
    if (-not (Test-WssIsWindows)) { return @() }
    try {
        $lines = & net.exe view "\\$HostName" 2>$null
        $shares = @(ConvertFrom-WssNetView -Lines $lines)
        # Disk shares only where the type column is recognisable; printers are excluded by Search anyway.
        return $shares
    } catch {
        Write-WssLog "net view \\$HostName failed: $($_.Exception.Message)"
        return @()
    }
}

$script:TargetCache = $null   # @{ Key; Time; Targets }

function Get-WssTargets {
    <# The searchable servers (see New-WssTargetList). Discovery runs CIM, registry and net view queries, so
       the result is reused for DiscoveryTtl seconds while the settings stay the same; -Refresh rediscovers. #>
    param([hashtable]$Config = (Get-WssConfig), [switch]$Refresh)
    $ttl = 0
    if ($Config.ContainsKey('DiscoveryTtl')) { $ttl = [int]$Config.DiscoveryTtl }
    $key = (@("$($Config.AutoDiscover)", "$($Config.UseNetBios)") + @($Config.Servers) + @('|') + @($Config.Exclude)) -join "`n"
    $c = $script:TargetCache
    if (-not $Refresh -and $ttl -gt 0 -and $c -and $c.Key -ceq $key -and ([DateTime]::UtcNow - $c.Time).TotalSeconds -lt $ttl) {
        return $c.Targets
    }
    $targets = @(New-WssTargetList -Config $Config)
    $script:TargetCache = $(if ($ttl -gt 0) { @{ Key = $key; Time = [DateTime]::UtcNow; Targets = $targets } } else { $null })
    return $targets
}

function New-WssTargetList {
    <#
      Builds the list of searchable servers:
      @{ Name; Machine; Sources=@('mapped-drive','config'); Shares=@(@{ Name; Unc; Drives=@('Z:') }) }
    #>
    param([hashtable]$Config = (Get-WssConfig))

    $servers = [ordered]@{}

    $addShare = {
        param([string]$Unc, [string]$Drive, [string]$Source)
        $u = ConvertFrom-WssUncPath $Unc
        if (-not $u) { return }
        $key = $u.Host.ToLowerInvariant()
        if (-not $servers.Contains($key)) {
            $servers[$key] = @{
                Name    = $u.Host
                Machine = Get-WssQueryMachine $u.Host $Config.UseNetBios
                Sources = New-Object System.Collections.ArrayList
                Shares  = New-Object System.Collections.ArrayList
            }
        }
        $srv = $servers[$key]
        if (-not ($srv.Sources -contains $Source)) { [void]$srv.Sources.Add($Source) }
        if (-not $u.Share) { return }
        $unc = "\\$($u.Host)\$($u.Share)"
        if ($u.Rest) { $unc = "$unc\$($u.Rest)" }
        $existing = $null
        foreach ($s in $srv.Shares) { if ($s.Unc -ieq $unc) { $existing = $s } }
        if (-not $existing) {
            $existing = @{ Name = $u.Share; Unc = $unc; Drives = New-Object System.Collections.ArrayList }
            [void]$srv.Shares.Add($existing)
        }
        if ($Drive -and -not ($existing.Drives -contains $Drive)) { [void]$existing.Drives.Add($Drive) }
    }

    if ($Config.AutoDiscover) {
        foreach ($d in Get-WssMappedDrives) { & $addShare $d.Unc $d.Drive 'mapped-drive' }
    }
    foreach ($s in $Config.Servers) {
        $u = ConvertFrom-WssUncPath $s
        if (-not $u) {
            # Allow a bare host name ("fs01") as shorthand for \\fs01
            if ($s -match '^[A-Za-z0-9._-]+$') { $u = ConvertFrom-WssUncPath "\\$s" } else {
                Write-WssLog "Ignoring invalid server entry '$s' (expected \\server or \\server\share)"
                continue
            }
        }
        & $addShare $u.Root $null 'config'
        if ($u.Rest -and $u.Share) { & $addShare "$($u.Root)\$($u.Rest)" $null 'config' }
    }

    # Servers configured without any share: enumerate shares with `net view`.
    foreach ($srv in $servers.Values) {
        if ($srv.Shares.Count -eq 0) {
            foreach ($name in Get-WssServerShares $srv.Name) { & $addShare "\\$($srv.Name)\$name" $null 'net-view' }
        }
    }

    $result = @()
    foreach ($srv in $servers.Values) {
        $excluded = $false
        foreach ($x in $Config.Exclude) {
            $xu = ConvertFrom-WssUncPath $x
            if (($xu -and -not $xu.Share -and $xu.Host -ieq $srv.Name) -or ($x -ieq $srv.Name) -or ($x -ieq $srv.Machine)) { $excluded = $true }
            if ($xu -and $xu.Share) {
                $keep = New-Object System.Collections.ArrayList
                foreach ($sh in $srv.Shares) { if (-not ($sh.Unc -ieq $xu.Root -or $sh.Unc -like "$($xu.Root)\*")) { [void]$keep.Add($sh) } }
                $srv.Shares = $keep
            }
        }
        if (-not $excluded) { $result += $srv }
    }
    return $result
}

# ---------------------------------------------------------------------------
# Query building
# ---------------------------------------------------------------------------

function ConvertTo-WssSqlString {
    <# Quotes a value as a Windows Search SQL string literal. #>
    param([string]$Value)
    return "'" + ($Value -replace "'", "''") + "'"
}

function Get-WssQueryTerms {
    <#
      Tokenises a user query: words, "quoted phrases", -exclusions and OR.
      Returns @{ Text; Phrase; Exclude; Or } items. Or=$true means "join with OR to the previous term".
    #>
    param([string]$Query)
    $terms = @()
    if (-not $Query) { return $terms }
    $pendingOr = $false
    $tokens = [regex]::Matches($Query, '(-?)"([^"]*)"|(\S+)')
    foreach ($m in $tokens) {
        $exclude = $false
        $phrase = $false
        if ($m.Groups[2].Success -and $m.Value.Contains('"')) {
            $text = $m.Groups[2].Value
            $phrase = $true
            $exclude = ($m.Groups[1].Value -eq '-')
        } else {
            $text = $m.Groups[3].Value
            if ($text -ceq 'OR' -or $text -eq '|') { $pendingOr = ($terms.Count -gt 0); continue }
            if ($text -ceq 'AND') { continue }
            if ($text.StartsWith('-') -and $text.Length -gt 1) { $exclude = $true; $text = $text.Substring(1) }
        }
        # Strip characters that would break the CONTAINS grammar.
        $text = ($text -replace '["*()\[\]{}]', ' ').Trim()
        $text = ($text -replace '\s+', ' ')
        if (-not $text -or $text -notmatch '[\p{L}\p{N}]') { continue }
        $terms += @{ Text = $text; Phrase = $phrase; Exclude = $exclude; Or = ($pendingOr -and -not $exclude) }
        $pendingOr = $false
    }
    return $terms
}

function Get-WssTermCondition {
    param([hashtable]$Term, [string]$Match)
    $text = $Term.Text
    $isPhrase = $Term.Phrase -or $text.Contains(' ')
    if ($isPhrase) { $containsArg = '"' + $text + '"' } else { $containsArg = '"' + $text + '*"' }
    $contains = 'CONTAINS(*, ' + (ConvertTo-WssSqlString $containsArg) + ')'
    $likeValue = '%' + ($text -replace '([\[%_])', '[$1]') + '%'
    $like = 'System.FileName LIKE ' + (ConvertTo-WssSqlString $likeValue)
    switch ($Match) {
        'filename' { return $like }
        'contents' { return $contains }
        default { return "($contains OR $like)" }
    }
}

function Format-WssSqlDate {
    <# Index dates are UTC. A value with Z or an offset is exact; without one it is this PC's local time.
       A plain date means that whole local day, so with -EndOfDay (modified_before) it includes the day. #>
    param([string]$Value, [string]$ParamName, [switch]$EndOfDay)
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $v = "$Value".Trim()
    $dt = [DateTime]::MinValue
    if ($v -match '^\d{4}-\d{2}-\d{2}$') {
        $ok = [DateTime]::TryParseExact($v, 'yyyy-MM-dd', $inv, [Globalization.DateTimeStyles]::None, [ref]$dt)
        if ($ok -and $EndOfDay) { $dt = $dt.AddDays(1).AddSeconds(-1) }
        if ($ok) { $dt = [DateTime]::SpecifyKind($dt, [DateTimeKind]::Local).ToUniversalTime() }
    } else {
        $styles = [Globalization.DateTimeStyles]::AdjustToUniversal
        if ($v -notmatch '(?i)(z|[+-]\d{2}(:?\d{2})?)$') { $styles = $styles -bor [Globalization.DateTimeStyles]::AssumeLocal }
        $ok = [DateTime]::TryParse($v, $inv, $styles, [ref]$dt)
    }
    if (-not $ok) {
        throw "Invalid date for ${ParamName}: '$Value' (use ISO 8601, e.g. 2024-05-31, 2024-05-31T12:00 or 2024-05-31T12:00:00Z)"
    }
    return "'" + $dt.ToString('yyyy-MM-dd HH:mm:ss', $inv) + "'"
}

function New-WssSearchSql {
    <# Builds a Windows Search SQL statement for one server and a set of scopes. #>
    param(
        [Parameter(Mandatory)][string]$Machine,
        [string[]]$Scopes = @(),
        [string]$Query,
        [ValidateSet('all', 'filename', 'contents')][string]$Match = 'all',
        [string[]]$Extensions = @(),
        [string]$Kind,
        [string]$Author,
        [string]$ModifiedAfter,
        [string]$ModifiedBefore,
        [bool]$IncludeFolders = $false,
        [ValidateSet('relevance', 'modified', 'name', 'size')][string]$Sort = 'relevance',
        [int]$Top = 50,
        # 0 = full query; 1 = basic columns; 2 = also no rank ordering; 3 = also no ORDER BY at all.
        [int]$Compat = 0
    )
    $where = New-Object System.Collections.ArrayList

    if ($Scopes.Count -gt 0) {
        $scopeConds = @()
        foreach ($s in $Scopes) {
            $u = ConvertFrom-WssUncPath $s
            if (-not $u) { throw "Scope '$s' is not a UNC path" }
            $url = "file://$($u.Host)"
            if ($u.Share) { $url += "/$($u.Share)" }
            if ($u.Rest) { $url += '/' + ($u.Rest -replace '\\', '/') }
            $scopeConds += 'SCOPE=' + (ConvertTo-WssSqlString $url)
        }
        if ($scopeConds.Count -eq 1) { [void]$where.Add($scopeConds[0]) } else { [void]$where.Add('(' + ($scopeConds -join ' OR ') + ')') }
    }

    $terms = @(Get-WssQueryTerms $Query)
    $hasText = $false
    if ($terms.Count -gt 0) {
        $expr = ''
        foreach ($t in $terms) {
            $cond = Get-WssTermCondition $t $Match
            if ($t.Exclude) { $cond = "NOT $cond" } else { $hasText = $true }
            if ($expr -eq '') { $expr = $cond }
            elseif ($t.Or) { $expr = "($expr OR $cond)" }
            else { $expr = "$expr AND $cond" }
        }
        [void]$where.Add("($expr)")
    }

    if ($Extensions -and $Extensions.Count -gt 0) {
        $extConds = @()
        foreach ($e in $Extensions) {
            $x = "$e".Trim().ToLowerInvariant()
            if (-not $x) { continue }
            if ($x -match '[^a-z0-9._+-]') { throw "Invalid file extension '$e'" }
            if (-not $x.StartsWith('.')) { $x = ".$x" }
            $extConds += 'System.FileExtension = ' + (ConvertTo-WssSqlString $x)
        }
        if ($extConds.Count -gt 0) { [void]$where.Add('(' + ($extConds -join ' OR ') + ')') }
    }
    if ($Kind) {
        if ($Kind -notmatch '^[A-Za-z]+$') { throw "Invalid kind '$Kind'" }
        [void]$where.Add('System.Kind = ' + (ConvertTo-WssSqlString $Kind.ToLowerInvariant()))
    }
    if ($Author) { [void]$where.Add('System.Author = ' + (ConvertTo-WssSqlString $Author)) }
    if ($ModifiedAfter) { [void]$where.Add('System.DateModified >= ' + (Format-WssSqlDate $ModifiedAfter 'modified_after')) }
    if ($ModifiedBefore) { [void]$where.Add('System.DateModified <= ' + (Format-WssSqlDate $ModifiedBefore 'modified_before' -EndOfDay)) }
    if (-not $IncludeFolders) { [void]$where.Add("System.ItemType <> 'Directory'") }

    switch ($Sort) {
        'modified' { $order = 'System.DateModified DESC' }
        'name' { $order = 'System.FileName ASC' }
        'size' { $order = 'System.Size DESC' }
        default { if ($hasText) { $order = 'System.Search.Rank DESC' } else { $order = 'System.DateModified DESC' } }
    }
    if ($Compat -ge 2 -and $order -like 'System.Search.Rank*') { $order = 'System.DateModified DESC' }
    $columns = $script:ResultColumns
    if ($Compat -ge 1) { $columns = $script:BasicColumns }

    if ($Machine -notmatch '^[A-Za-z0-9._-]+$') { throw "Invalid server name '$Machine'" }
    $sql = "SELECT TOP $Top " + ($columns -join ', ') + " FROM $Machine.SystemIndex"
    if ($where.Count -gt 0) { $sql += ' WHERE ' + ($where -join ' AND ') }
    if ($Compat -lt 3) { $sql += " ORDER BY $order" }
    return $sql
}

# ---------------------------------------------------------------------------
# Query execution
# ---------------------------------------------------------------------------

function Invoke-WssQuery {
    <# Executes Windows Search SQL via the Search.CollatorDSO OLE DB provider (ADODB COM). #>
    param([string]$Machine, [string]$Sql, [int]$TimeoutSeconds = 30)
    if ($script:QueryExecutor) { return @(& $script:QueryExecutor $Machine $Sql $TimeoutSeconds) }
    if (-not (Test-WssIsWindows)) { throw 'Windows Search queries are only supported on Windows.' }

    $conn = New-Object -ComObject ADODB.Connection
    $rs = $null
    try {
        $conn.ConnectionTimeout = $TimeoutSeconds
        $conn.CommandTimeout = $TimeoutSeconds
        $conn.Open("Provider=Search.CollatorDSO;Extended Properties='Application=Windows';")
        $rs = New-Object -ComObject ADODB.Recordset
        $rs.Open($Sql, $conn)
        $rows = New-Object System.Collections.ArrayList
        while (-not $rs.EOF) {
            $row = @{}
            foreach ($f in $rs.Fields) { $row[$f.Name] = $f.Value }
            [void]$rows.Add($row)
            $rs.MoveNext()
        }
        return $rows.ToArray()
    } finally {
        if ($rs) { try { if ($rs.State -ne 0) { $rs.Close() } } catch { }; [void][Runtime.InteropServices.Marshal]::ReleaseComObject($rs) }
        try { if ($conn.State -ne 0) { $conn.Close() } } catch { }
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($conn)
    }
}

function Test-WssClassNotRegistered {
    param($Exception)
    $code = Get-WssErrorCode $Exception
    return ($code -in @('0x80040154', '0x800401F3')) -or ("$($Exception.Message)" -match 'class not registered|Klasse nicht registriert')
}

function Invoke-WssCompatQuery {
    <# Runs an index query built by $BuildSql (receives the compat level). If the client reports "class not
       registered" - seen for single servers while others work in the same process - it retries with simpler
       SQL. The level that worked is remembered per server so later searches skip the failing variants. #>
    param([string]$Machine, [scriptblock]$BuildSql, [int]$TimeoutSeconds = 30)
    $level = 0
    if ($script:CompatLevel.ContainsKey($Machine)) { $level = $script:CompatLevel[$Machine] }
    while ($true) {
        $sql = & $BuildSql $level
        Write-WssLog "Query [$Machine]: $sql"
        try {
            $rows = @(Invoke-WssQuery -Machine $Machine -Sql $sql -TimeoutSeconds $TimeoutSeconds)
        } catch {
            if ($level -ge $script:MaxCompatLevel -or -not (Test-WssClassNotRegistered $_.Exception)) { throw }
            $level++
            Write-WssLog "Query [$Machine] failed with 'class not registered'; retrying with simpler SQL (level $level)"
            continue
        }
        $script:CompatLevel[$Machine] = $level
        return $rows
    }
}

function ConvertTo-WssIso {
    param($Value)
    if ($null -eq $Value -or $Value -is [DBNull]) { return $null }
    if ($Value -is [DateTime]) { return $Value.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture) }
    return "$Value"
}

function ConvertTo-WssPlain {
    param($Value)
    if ($null -eq $Value -or $Value -is [DBNull]) { return $null }
    if ($Value -is [DateTime]) { return ConvertTo-WssIso $Value }
    if ($Value -is [array]) { return @($Value | ForEach-Object { "$_" }) }
    return $Value
}

function Get-WssRowValue {
    param([hashtable]$Row, [string]$Name)
    foreach ($k in $Row.Keys) { if ($k -ieq $Name) { return $Row[$k] } }
    return $null
}

function Convert-WssUncToDrivePath {
    param([string]$Unc, $Targets)
    foreach ($srv in $Targets) {
        foreach ($sh in $srv.Shares) {
            if ($sh.Drives.Count -eq 0) { continue }
            foreach ($root in @($sh.Unc, ("\\" + $srv.Machine + $sh.Unc.Substring(2 + $srv.Name.Length)))) {
                if ($Unc -ieq $root) { return $sh.Drives[0] + '\' }
                if ($Unc.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) {
                    return $sh.Drives[0] + $Unc.Substring($root.Length)
                }
            }
        }
    }
    return $null
}

function ConvertTo-WssResult {
    param([hashtable]$Row, [string]$ServerName, $Targets)
    $url = Get-WssRowValue $Row 'System.ItemUrl'
    $display = Get-WssRowValue $Row 'System.ItemPathDisplay'
    $unc = $null
    if ($url -and "$url" -match '^(?i)file:') {
        $u = ConvertFrom-WssUncPath "$url"
        if ($u) { $unc = $u.Root; if ($u.Rest) { $unc += '\' + $u.Rest } }
    }
    if (-not $unc -and $display) { $unc = "$display" }
    $result = [ordered]@{
        name     = ConvertTo-WssPlain (Get-WssRowValue $Row 'System.FileName')
        path     = $unc
        server   = $ServerName
    }
    if ($unc) {
        $drivePath = Convert-WssUncToDrivePath $unc $Targets
        if ($drivePath) { $result.drive_path = $drivePath }
    }
    $type = ConvertTo-WssPlain (Get-WssRowValue $Row 'System.ItemTypeText')
    if ($type) { $result.type = $type }
    $size = Get-WssRowValue $Row 'System.Size'
    if ($null -ne $size -and -not ($size -is [DBNull])) { $result.size = [int64]$size }
    $modified = ConvertTo-WssIso (Get-WssRowValue $Row 'System.DateModified')
    if ($modified) { $result.modified = $modified }
    $created = ConvertTo-WssIso (Get-WssRowValue $Row 'System.DateCreated')
    if ($created) { $result.created = $created }
    $title = ConvertTo-WssPlain (Get-WssRowValue $Row 'System.Title')
    if ($title) { $result.title = $title }
    $author = ConvertTo-WssPlain (Get-WssRowValue $Row 'System.Author')
    if ($author) { $result.author = @($author) }
    $kind = ConvertTo-WssPlain (Get-WssRowValue $Row 'System.Kind')
    if ($kind) { $result.kind = @($kind) }
    $rank = Get-WssRowValue $Row 'System.Search.Rank'
    if ($null -ne $rank -and -not ($rank -is [DBNull])) { $result.rank = [int64]$rank }
    return $result
}

function Get-WssErrorCode {
    <# Returns the HRESULT of a failed index query as '0x8004....', or $null. COM errors are usually wrapped
       in a MethodInvocationException, so the exception chain is searched for the COM HRESULT. #>
    param($Exception)
    $e = $Exception
    while ($e) {
        $h = 0
        try { $h = [int]$e.HResult } catch { }
        if ($e -is [Runtime.InteropServices.COMException] -and $h -ne 0) { return ('0x{0:X8}' -f $h) }
        $e = $e.InnerException
    }
    $m = [regex]::Match("$($Exception.Message)", '0x[0-9A-Fa-f]{8}')
    if ($m.Success) { return $m.Value.ToUpperInvariant().Replace('0X', '0x') }
    return $null
}

function Get-WssErrorMessage {
    <# Adds the error code and a hint matching the actual failure. Only claims a missing search service
       where that is a plausible cause, so access or client problems are not reported as server problems. #>
    param($ErrorRecord, [string]$Machine)
    $ex = $ErrorRecord.Exception
    $msg = "$($ex.Message)".Trim()
    $code = Get-WssErrorCode $ex
    if ($code -and $msg -notmatch [regex]::Escape($code)) { $msg = "$msg (error $code)" }
    $alias = "If File Explorer on this PC finds words inside files on this drive, the server's search service works and '$Machine' is probably not the file server's real name (DFS namespace or DNS alias): add the real server, e.g. \\realserver\share, to the 'servers' setting."
    $hint = switch -Regex ("$code $msg") {
        '0x80040E37|table does not exist|Tabelle' {
            "Hint: the search index on '$Machine' could not be opened. Either the Windows Search Service is not running on '$Machine' or does not index this share, or: $alias"; break
        }
        '0x80070005|access is denied|Zugriff verweigert' {
            "Hint: access denied. The current Windows user may not query the search index on '$Machine'; this is a permission problem, not a missing search service."; break
        }
        '0x80040154|0x800401F3|class not registered|Klasse nicht registriert' {
            $bits = ''
            if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) { $bits = ' This MCP server runs as a 32-bit PowerShell process.' }
            if ($script:RestoredEnv.Count -gt 0) { $bits += " The app started this server without these environment variables (restored): $($script:RestoredEnv -join ', ')." }
            "Hint: this PC could not run the index query for '$Machine' because a COM class is not registered here (Search.CollatorDSO / ADODB, or a component the query needs). The problem is on this PC, not on the file server.$bits"; break
        }
        '0x80040E31|timeout|time-out|Zeitlimit' {
            "Hint: the index query on '$Machine' timed out. Narrow the search with 'path' or raise 'queryTimeout'."; break
        }
        '0x800706BA|0x800706D9|0x80070035|0x80070043|RPC' {
            "Hint: '$Machine' could not be reached for an index query (name not resolvable, firewall, or the Windows Search Service is stopped there). $alias"; break
        }
        default { '' }
    }
    if ($hint) { return "$msg $hint" }
    return $msg
}

function Select-WssTargets {
    <# Applies the optional server / path filters. Returns @{ Server; Scopes } pairs. #>
    param($Targets, [string]$Server, [string]$Path)
    $plans = @()
    $pathUnc = $null
    if ($Path) {
        $pathUnc = Resolve-WssPath $Path $Targets
    }
    foreach ($srv in $Targets) {
        if ($Server -and -not ($srv.Name -ieq $Server -or $srv.Machine -ieq $Server)) { continue }
        if ($pathUnc) {
            $u = ConvertFrom-WssUncPath $pathUnc
            if (-not ($u.Host -ieq $srv.Name -or $u.Host -ieq $srv.Machine)) { continue }
            $plans += @{ Server = $srv; Scopes = @("\\$($srv.Machine)\$($u.Share)" + $(if ($u.Rest) { "\$($u.Rest)" } else { '' })) }
            continue
        }
        $scopes = @()
        foreach ($sh in $srv.Shares) { $scopes += ("\\" + $srv.Machine + $sh.Unc.Substring(2 + $srv.Name.Length)) }
        $plans += @{ Server = $srv; Scopes = $scopes }
    }
    return $plans
}

function Search-Wss {
    param([hashtable]$Arguments, [hashtable]$Config = (Get-WssConfig), $Targets = $null)
    if ($null -eq $Targets) { $Targets = @(Get-WssTargets -Config $Config) }
    if ($Targets.Count -eq 0) {
        throw 'No Windows servers configured or discovered. Map a network drive (e.g. net use Z: \\server\share) or set the "servers" plugin option.'
    }
    $limit = ConvertTo-WssInt $Arguments.max_results $Config.MaxResults 1 500
    $match = 'all'; if ($Arguments.match) { $match = "$($Arguments.match)".ToLowerInvariant() }
    $sort = 'relevance'; if ($Arguments.sort) { $sort = "$($Arguments.sort)".ToLowerInvariant() }
    $exts = @(); if ($Arguments.extensions) { $exts = @($Arguments.extensions) }
    if ($match -notin @('all', 'filename', 'contents')) { throw "Invalid match '$match' (use all, filename or contents)" }
    if ($sort -notin @('relevance', 'modified', 'name', 'size')) { throw "Invalid sort '$sort' (use relevance, modified, name or size)" }

    if (-not $Arguments.query -and $exts.Count -eq 0 -and -not $Arguments.kind -and -not $Arguments.modified_after -and -not $Arguments.modified_before -and -not $Arguments.author) {
        throw 'Provide a query or at least one filter (extensions, kind, author, modified_after, modified_before).'
    }

    $policy = Get-WssPolicy -Config $Config -Targets $Targets
    if ($Arguments.path) {
        # Only known shares: their .claude-policy files are loaded and excluded shares stay excluded.
        Assert-WssAllowed (Resolve-WssPath $Arguments.path $Targets) $policy
    }

    $plans = @(Select-WssTargets $Targets $Arguments.server $Arguments.path)
    if ($plans.Count -eq 0) {
        $names = ($Targets | ForEach-Object { $_.Name }) -join ', '
        throw "No matching server for server='$($Arguments.server)' path='$($Arguments.path)'. Known servers: $names"
    }
    # Skip scopes on shares that are blocked entirely (e.g. unreadable policy file).
    foreach ($plan in $plans) {
        $plan.Scopes = @($plan.Scopes | Where-Object { -not (Test-WssBlocked $_ $policy) })
    }
    $plans = @($plans | Where-Object { $_.Scopes.Count -gt 0 })
    if ($plans.Count -eq 0) { throw 'All matching shares are blocked by the access policy.' }
    $offset = ConvertTo-WssInt $Arguments.offset 0 0 4500
    $options = @{
        Match = $match; Sort = $sort; Extensions = $exts
        # One more than needed per server tells whether there is a next page.
        Need = $offset + $limit + 1
    }
    $jobs = @(foreach ($plan in $plans) {
            @{ Plan = $plan; Arguments = $Arguments; Options = $options; Targets = $Targets; Policy = $policy; Timeout = $Config.QueryTimeout; CompatLevels = $script:CompatLevel; RestoredEnv = @($script:RestoredEnv) }
        })
    $outcomes = @(Invoke-WssServerSearches -Jobs $jobs -TimeoutSeconds $Config.QueryTimeout)

    $hidden = 0
    $results = New-Object System.Collections.ArrayList
    $errors = New-Object System.Collections.ArrayList
    $queried = @()
    foreach ($o in $outcomes) {
        $queried += $o.Name
        if ($null -ne $o.Compat) { $script:CompatLevel[$o.Machine] = $o.Compat }
        if ($o.Invalid) { throw $o.Error }
        if ($o.Error) { [void]$errors.Add([ordered]@{ server = $o.Name; error = $o.Error }); continue }
        $hidden += $o.Hidden
        foreach ($res in $o.Results) { [void]$results.Add($res) }
    }

    $sorted = @($results)
    if ($plans.Count -gt 1) {
        switch ($sort) {
            'modified' { $sorted = @($results | Sort-Object -Property @{ Expression = { $_.modified }; Descending = $true }) }
            'name' { $sorted = @($results | Sort-Object -Property @{ Expression = { $_.name } }) }
            'size' { $sorted = @($results | Sort-Object -Property @{ Expression = { $_.size }; Descending = $true }) }
            default {
                $sorted = @($results | Sort-Object -Property @{ Expression = { if ($_.Contains('rank')) { $_.rank } else { 0 } }; Descending = $true }, @{ Expression = { $_.modified }; Descending = $true })
            }
        }
    }
    $more = $sorted.Count -gt ($offset + $limit)
    if ($offset -ge $sorted.Count) { $sorted = @() }
    else { $sorted = @($sorted[$offset..([Math]::Min($sorted.Count, $offset + $limit) - 1)]) }

    if ($Arguments.query -and (ConvertTo-WssBool $Arguments.snippets $false)) {
        [void](Add-WssSnippets -Results $sorted -Query $Arguments.query -Config $Config -Targets $Targets -Policy $policy)
    }

    $out = [ordered]@{
        servers_queried  = @($queried)
        result_count     = $sorted.Count
        hidden_by_policy = $hidden
    }
    if ($offset -gt 0) { $out.offset = $offset }
    if ($more) { $out.next_offset = $offset + $limit }
    if ($hidden -gt 0) {
        $out.policy_note = "$hidden matching file(s) were hidden from Claude by the access policy. Tell the user; do not try to access them another way."
    }
    $out.results = @($sorted)
    if ($errors.Count -gt 0) { $out.errors = @($errors) }
    if ($errors.Count -eq $plans.Count -and $plans.Count -gt 0) {
        throw ('All index queries failed: ' + (($errors | ForEach-Object { "$($_.server): $($_.error)" }) -join ' | '))
    }
    return $out
}

function Search-WssServer {
    <# Runs the index query of one server and filters the hits by the access policy. Runs in the server's
       own session or in a runspace of the search pool, so it never throws and only uses its parameters. #>
    param($Plan, [hashtable]$Arguments, [hashtable]$Options, $Targets, $Policy, [int]$Timeout = 30, [hashtable]$CompatLevels, [string[]]$RestoredEnv)
    if ($CompatLevels) { foreach ($k in @($CompatLevels.Keys)) { $script:CompatLevel[$k] = $CompatLevels[$k] } }
    # For the error hints (a runspace has not seen the server's start-up).
    if ($RestoredEnv) { $script:RestoredEnv = @($RestoredEnv) }
    $srv = $Plan.Server
    $out = @{ Name = $srv.Name; Machine = $srv.Machine; Results = @(); Hidden = 0; Error = $null; Invalid = $false; Compat = $null }
    try {
        $need = $Options.Need
        # Fetch more than requested so blocked items do not crowd out allowed ones; widen if needed.
        $fetch = [Math]::Min($need * 3 + 20, 2000)
        while ($true) {
            $build = {
                param($compat)
                New-WssSearchSql -Machine $srv.Machine -Scopes $Plan.Scopes -Query $Arguments.query -Match $Options.Match `
                    -Extensions $Options.Extensions -Kind $Arguments.kind -Author $Arguments.author `
                    -ModifiedAfter $Arguments.modified_after -ModifiedBefore $Arguments.modified_before `
                    -IncludeFolders (ConvertTo-WssBool $Arguments.include_folders $false) -Sort $Options.Sort -Top $fetch -Compat $compat
            }
            $rows = @(Invoke-WssCompatQuery -Machine $srv.Machine -BuildSql $build -TimeoutSeconds $Timeout)
            $allowed = New-Object System.Collections.ArrayList
            $hidden = 0
            foreach ($r in $rows) {
                $res = ConvertTo-WssResult $r $srv.Name $Targets
                if ($res.path -and (Test-WssBlocked $res.path $Policy)) { $hidden++; continue }
                [void]$allowed.Add($res)
            }
            if ($allowed.Count -ge $need -or $rows.Count -lt $fetch -or $fetch -ge 5000) { break }
            $fetch = [Math]::Min($fetch * 4, 5000)
        }
        $out.Hidden = $hidden
        $out.Results = @($allowed | Select-Object -First $need)
    } catch {
        if ($_.Exception.Message -match '^Invalid ') { $out.Invalid = $true; $out.Error = $_.Exception.Message }
        else { $out.Error = Get-WssErrorMessage $_ $srv.Machine }
    }
    if ($script:CompatLevel.ContainsKey($srv.Machine)) { $out.Compat = $script:CompatLevel[$srv.Machine] }
    return $out
}

$script:ModulePath = $PSCommandPath
$script:SearchPool = $null
$script:FakeBackendPath = $null

function Invoke-WssServerSearches {
    <# Runs Search-WssServer for each job. Several servers are queried in parallel in a runspace pool, so one
       slow or unreachable server costs one timeout instead of adding up. Test backends injected into this
       session can't be used from other runspaces, so they run one after another (the fake backend file can). #>
    param([array]$Jobs, [int]$TimeoutSeconds = 30)
    $parallel = $Jobs.Count -gt 1 -and $script:ModulePath -and (-not $script:QueryExecutor -or $script:FakeBackendPath)
    if ($parallel -and -not $script:SearchPool) {
        try {
            $iss = [Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
            # Execution policies exist only on Windows (elsewhere Open() fails when one is set).
            if (Test-WssIsWindows) { $iss.ExecutionPolicy = 'Bypass' }
            $iss.ImportPSModule(@($script:ModulePath))
            $pool = [runspacefactory]::CreateRunspacePool(1, 8, $iss, $Host)
            $pool.Open()
            $script:SearchPool = $pool
        } catch {
            Write-WssLog "Parallel search unavailable, querying servers one after another: $($_.Exception.Message)"
            $script:ModulePath = $null
            $parallel = $false
        }
    }
    if (-not $parallel) { return @(foreach ($j in $Jobs) { Search-WssServer @j }) }
    $worker = {
        param($Job, $FakeBackend)
        if ($FakeBackend) { & (Get-Module WindowsServerSearch) { param($p) if (-not $script:FakeBackendPath) { Enable-WssFakeBackend $p } } $FakeBackend }
        Search-WssServer @Job
    }
    $running = @(foreach ($j in $Jobs) {
            $ps = [powershell]::Create()
            $ps.RunspacePool = $script:SearchPool
            [void]$ps.AddScript($worker).AddArgument($j).AddArgument($script:FakeBackendPath)
            @{ PS = $ps; Handle = $ps.BeginInvoke(); Job = $j }
        })
    # Each query has its own timeout; compat retries may run a few in a row.
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds * 2 + 15)
    $out = @()
    foreach ($r in $running) {
        $srv = $r.Job.Plan.Server
        $left = [int][Math]::Max(0, ($deadline - [DateTime]::UtcNow).TotalMilliseconds)
        if (-not $r.Handle.AsyncWaitHandle.WaitOne($left)) {
            [void]$r.PS.BeginStop($null, $null)
            $out += @{ Name = $srv.Name; Machine = $srv.Machine; Results = @(); Hidden = 0; Invalid = $false; Compat = $null
                Error = "The index query on '$($srv.Machine)' did not answer in time. Narrow the search with 'path' or raise 'queryTimeout'." }
            continue
        }
        $res = $null
        try {
            foreach ($o in $r.PS.EndInvoke($r.Handle)) { if ($null -ne $o -and $o.PSObject.BaseObject -is [hashtable]) { $res = $o.PSObject.BaseObject } }
        } catch { Write-WssLog "Search on $($srv.Name) failed: $($_.Exception.Message)" }
        if (-not $res) {
            $msg = $(if ($r.PS.Streams.Error.Count -gt 0) { "$($r.PS.Streams.Error[0])" } else { 'no result' })
            $res = @{ Name = $srv.Name; Machine = $srv.Machine; Results = @(); Hidden = 0; Invalid = $false; Compat = $null; Error = "Search failed: $msg" }
        }
        $r.PS.Dispose()
        $out += $res
    }
    return $out
}

function Test-WssServer {
    param($Server, [hashtable]$Config)
    $scopes = @()
    foreach ($sh in $Server.Shares) { $scopes += ("\\" + $Server.Machine + $sh.Unc.Substring(2 + $Server.Name.Length)) }
    $sql = "SELECT TOP 1 System.ItemUrl FROM $($Server.Machine).SystemIndex"
    if ($scopes.Count -gt 0) {
        $conds = @()
        foreach ($s in $scopes) {
            $u = ConvertFrom-WssUncPath $s
            $url = "file://$($u.Host)/$($u.Share)"
            if ($u.Rest) { $url += '/' + ($u.Rest -replace '\\', '/') }
            $conds += 'SCOPE=' + (ConvertTo-WssSqlString $url)
        }
        $sql += ' WHERE ' + ($conds -join ' OR ')
    }
    try {
        $rows = @(Invoke-WssQuery -Machine $Server.Machine -Sql $sql -TimeoutSeconds $Config.QueryTimeout)
        if ($rows.Count -gt 0) { return [ordered]@{ status = 'ok'; detail = 'Index reachable and returned results.' } }
        return [ordered]@{ status = 'empty'; detail = 'Index reachable but returned no items for these shares (folder may not be indexed on the server).' }
    } catch {
        return [ordered]@{ status = 'error'; detail = (Get-WssErrorMessage $_ $Server.Machine) }
    }
}

function Get-WssServerList {
    param([hashtable]$Arguments, [hashtable]$Config = (Get-WssConfig))
    $targets = @(Get-WssTargets -Config $Config -Refresh)
    $policy = Get-WssPolicy -Config $Config -Targets $targets
    $check = ConvertTo-WssBool $Arguments.check $false
    $list = @()
    foreach ($srv in $targets) {
        $shares = @()
        foreach ($sh in $srv.Shares) {
            $entryShare = [ordered]@{ name = $sh.Name; path = $sh.Unc; drives = @($sh.Drives) }
            $rule = Test-WssBlocked $sh.Unc $policy
            if ($rule) { $entryShare.blocked_by_policy = "$($rule.Source): $($rule.Pattern)" }
            $shares += $entryShare
        }
        $entry = [ordered]@{
            name           = $srv.Name
            query_machine  = $srv.Machine
            sources        = @($srv.Sources)
            shares         = @($shares)
        }
        if ($check) { $entry.index = Test-WssServer $srv $Config }
        $list += $entry
    }
    $out = [ordered]@{
        servers = @($list)
        config  = [ordered]@{
            auto_discover    = $Config.AutoDiscover
            configured       = @($Config.Servers)
            excluded         = @($Config.Exclude)
            max_results      = $Config.MaxResults
        }
        access_policy = (Get-WssPolicySummary $policy)
        write         = (Get-WssWriteStatus $Config)
    }
    if ($list.Count -eq 0) {
        $out.hint = 'No servers found. Map a network drive to a Windows file server (net use Z: \\server\share) or configure the "servers" option of the plugin with UNC paths like \\server\share.'
    }
    return $out
}

# ---------------------------------------------------------------------------
# File access (restricted to known shares)
# ---------------------------------------------------------------------------

function Resolve-WssPath {
    <#
      Converts a drive path (Z:\x) or UNC path into a normalized UNC path and checks that it lies
      within a known share. Throws otherwise.
    #>
    param([string]$Path, $Targets)
    if (-not $Path) { throw 'path is required' }
    $p = $Path.Trim() -replace '/', '\'
    if ($p -match '^([A-Za-z]:)(\\.*)?$') {
        $drive = $Matches[1].ToUpperInvariant()
        $rest = ''; if ($Matches.Count -gt 2 -and $Matches[2]) { $rest = $Matches[2] }
        $found = $null
        foreach ($srv in $Targets) { foreach ($sh in $srv.Shares) { if ($sh.Drives -contains $drive) { $found = $sh.Unc } } }
        if (-not $found) { throw "Drive $drive is not a mapped drive of a known Windows server. If it was mapped just now, call list_servers to refresh." }
        $p = $found + $rest
    }
    if ($p -match '^(?i)file:') { $p = (ConvertFrom-WssUncPath $p).Root + $(if ((ConvertFrom-WssUncPath $p).Rest) { '\' + (ConvertFrom-WssUncPath $p).Rest } else { '' }) }
    $u = ConvertFrom-WssUncPath $p
    if (-not $u -or -not $u.Share) { throw "Path '$Path' is not a UNC path (\\server\share\...) or mapped drive path." }
    # Normalise . and .. segments to prevent escaping the share.
    $segments = New-Object System.Collections.ArrayList
    foreach ($seg in ($u.Rest -split '\\')) {
        if ($seg -eq '' -or $seg -eq '.') { continue }
        if ($seg -eq '..') { if ($segments.Count -gt 0) { $segments.RemoveAt($segments.Count - 1) }; continue }
        [void]$segments.Add($seg)
    }
    $norm = "\\$($u.Host)\$($u.Share)"
    if ($segments.Count -gt 0) { $norm += '\' + ($segments -join '\') }

    foreach ($srv in $Targets) {
        if (-not ($u.Host -ieq $srv.Name -or $u.Host -ieq $srv.Machine)) { continue }
        foreach ($sh in $srv.Shares) {
            $root = "\\$($u.Host)" + $sh.Unc.Substring(2 + $srv.Name.Length)
            if ($norm -ieq $root -or $norm.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) { return $norm }
        }
    }
    throw "Path '$Path' is outside the known Windows server shares. Use list_servers to see (and refresh) the available shares."
}

function ConvertFrom-WssXmlText {
    param([string]$Xml, [string]$ParagraphTag, [string]$TextTag)
    if (-not $Xml) { return '' }
    $s = $Xml
    # Tracked deletions and field codes (TOC \o, HYPERLINK "...") are not part of the visible text.
    # A self-closing <w:del .../> (deleted paragraph mark) has no content and must not start a match.
    $s = $s -replace '(?s)<w:del\b[^>]*(?<!/)>.*?</w:del>', '' -replace '(?s)<w:instrText\b[^>]*(?<!/)>.*?</w:instrText>', ''
    if ($ParagraphTag) { $s = $s -replace "</$ParagraphTag>", "`n" }
    $s = $s -replace '<w:tab/>', "`t" -replace '<w:br/>', "`n" -replace '<w:cr/>', "`n" -replace '<a:br/>', "`n"
    $s = $s -replace '<[^>]+>', ''
    return [System.Net.WebUtility]::HtmlDecode($s)
}

function Get-WssZipEntryText {
    param($Zip, [string]$Name)
    $e = $Zip.GetEntry($Name)
    if (-not $e) { return $null }
    $sr = New-Object IO.StreamReader($e.Open(), [Text.Encoding]::UTF8)
    try { return $sr.ReadToEnd() } finally { $sr.Dispose() }
}

function Get-WssOoxmlRels {
    <# Relationship id -> part name for an OOXML part, e.g. xl/workbook.xml: rId1 -> xl/worksheets/sheet1.xml #>
    param($Zip, [string]$PartName)
    $dir = ''; $file = $PartName
    $slash = $PartName.LastIndexOf('/')
    if ($slash -ge 0) { $dir = $PartName.Substring(0, $slash); $file = $PartName.Substring($slash + 1) }
    $relsName = $(if ($dir) { "$dir/_rels/$file.rels" } else { "_rels/$file.rels" })
    $map = @{}
    $xml = Get-WssZipEntryText $Zip $relsName
    if (-not $xml) { return $map }
    foreach ($m in [regex]::Matches($xml, '<Relationship\b[^>]*>')) {
        $id = [regex]::Match($m.Value, '\bId="([^"]*)"').Groups[1].Value
        $target = [regex]::Match($m.Value, '\bTarget="([^"]*)"').Groups[1].Value
        if (-not $id -or -not $target -or $m.Value -match 'TargetMode="External"') { continue }
        if ($target.StartsWith('/')) { $path = $target.TrimStart('/') } else { $path = $(if ($dir) { "$dir/$target" } else { $target }) }
        # Resolve ../ segments (pptx slides refer to ../notesSlides/...).
        $parts = New-Object System.Collections.ArrayList
        foreach ($seg in $path -split '/') {
            if ($seg -eq '..') { if ($parts.Count -gt 0) { $parts.RemoveAt($parts.Count - 1) } } elseif ($seg -and $seg -ne '.') { [void]$parts.Add($seg) }
        }
        $map[$id] = ($parts -join '/')
    }
    return $map
}

function Get-WssNumberedParts {
    <# Zip entries such as ppt/slides/slide12.xml in numeric order. #>
    param($Zip, [string]$Pattern)
    return @($Zip.Entries | Where-Object { $_.FullName -match $Pattern } |
        Sort-Object { [int]([regex]::Match($_.FullName, '(\d+)\.xml$').Groups[1].Value) } | ForEach-Object { $_.FullName })
}

function ConvertFrom-WssWordXml {
    <# Text of a WordprocessingML part. Table cells are separated by tabs, table rows by line breaks. #>
    param([string]$Xml)
    if (-not $Xml) { return '' }
    $s = [regex]::Replace($Xml, '(?s)<w:tc\b[^>]*>(.*?)</w:tc>', {
            param($m)
            # Paragraphs inside a cell become spaces so the row stays on one line.
            $cell = (ConvertFrom-WssXmlText ($m.Groups[1].Value -replace '</w:p>', ' ')) -replace '[\r\n\t]+', ' '
            '<w:t>' + [System.Net.WebUtility]::HtmlEncode($cell.Trim()) + "`t</w:t>"
        })
    $s = $s -replace '</w:tr>', "`n"
    return (ConvertFrom-WssXmlText $s 'w:p') -replace "`t`n", "`n"
}

function Get-WssDocxText {
    param($Zip)
    $sb = New-Object Text.StringBuilder
    [void]$sb.AppendLine((ConvertFrom-WssWordXml (Get-WssZipEntryText $Zip 'word/document.xml')).Trim())
    foreach ($kind in 'header', 'footer') {
        $seen = @{}
        foreach ($part in Get-WssNumberedParts $Zip "^word/$kind(\d+)\.xml$") {
            $t = (ConvertFrom-WssWordXml (Get-WssZipEntryText $Zip $part)).Trim()
            # Documents often repeat the same header in several sections.
            if ($t -and -not $seen.ContainsKey($t)) { $seen[$t] = $true; [void]$sb.AppendLine("--- ${kind}: $t") }
        }
    }
    foreach ($p in @(@{ Part = 'word/footnotes.xml'; Tag = 'w:footnote'; Label = 'Footnotes' }, @{ Part = 'word/endnotes.xml'; Tag = 'w:endnote'; Label = 'Endnotes' })) {
        $xml = Get-WssZipEntryText $Zip $p.Part
        if (-not $xml) { continue }
        $notes = @()
        foreach ($m in [regex]::Matches($xml, "(?s)<$($p.Tag)\b([^>]*)>(.*?)</$($p.Tag)>")) {
            if ($m.Groups[1].Value -match 'w:type="(separator|continuationSeparator|continuationNotice)"') { continue }
            $id = [regex]::Match($m.Groups[1].Value, 'w:id="(-?\d+)"').Groups[1].Value
            $t = ((ConvertFrom-WssWordXml $m.Groups[2].Value) -replace '\s+', ' ').Trim()
            if ($t) { $notes += "[$id] $t" }
        }
        if ($notes.Count -gt 0) { [void]$sb.AppendLine("--- $($p.Label) ---"); [void]$sb.AppendLine(($notes -join "`n")) }
    }
    $xml = Get-WssZipEntryText $Zip 'word/comments.xml'
    if ($xml) {
        $comments = @()
        foreach ($m in [regex]::Matches($xml, '(?s)<w:comment\b([^>]*)>(.*?)</w:comment>')) {
            $author = [System.Net.WebUtility]::HtmlDecode([regex]::Match($m.Groups[1].Value, 'w:author="([^"]*)"').Groups[1].Value)
            $t = ((ConvertFrom-WssWordXml $m.Groups[2].Value) -replace '\s+', ' ').Trim()
            if ($t) { $comments += $(if ($author) { "${author}: $t" } else { $t }) }
        }
        if ($comments.Count -gt 0) { [void]$sb.AppendLine('--- Comments ---'); [void]$sb.AppendLine(($comments -join "`n")) }
    }
    return $sb.ToString().Trim()
}

function Get-WssPptxText {
    <# Slides in presentation order (presentation.xml), with speaker notes. #>
    param($Zip)
    $slides = @()
    $pres = Get-WssZipEntryText $Zip 'ppt/presentation.xml'
    if ($pres) {
        $rels = Get-WssOoxmlRels $Zip 'ppt/presentation.xml'
        foreach ($m in [regex]::Matches($pres, '<p:sldId\b[^>]*\br:id="([^"]*)"')) {
            $part = $rels[$m.Groups[1].Value]
            if ($part -and $Zip.GetEntry($part)) { $slides += $part }
        }
    }
    if ($slides.Count -eq 0) { $slides = @(Get-WssNumberedParts $Zip '^ppt/slides/slide(\d+)\.xml$') }
    $sb = New-Object Text.StringBuilder
    $i = 0
    foreach ($part in $slides) {
        $i++
        [void]$sb.AppendLine("--- Slide $i ---")
        [void]$sb.AppendLine((ConvertFrom-WssXmlText (Get-WssZipEntryText $Zip $part) 'a:p').Trim())
        $notesPart = $null
        foreach ($target in (Get-WssOoxmlRels $Zip $part).Values) { if ($target -match '^ppt/notesSlides/') { $notesPart = $target } }
        if ($notesPart) {
            $nx = Get-WssZipEntryText $Zip $notesPart
            # Only the notes body placeholder; the others hold the slide image and the slide number.
            $body = @([regex]::Matches("$nx", '(?s)<p:sp\b[^>]*>(?:(?!</p:sp>).)*?<p:ph\b[^>]*type="body"(?:(?!</p:sp>).)*</p:sp>') | ForEach-Object { $_.Value })
            $notes = (ConvertFrom-WssXmlText ($body -join "`n") 'a:p').Trim()
            if ($notes) { [void]$sb.AppendLine("Notes: $notes") }
        }
    }
    return $sb.ToString().Trim()
}

function ConvertFrom-WssCellRef {
    <# Zero-based column index of a cell reference such as AB12. #>
    param([string]$Ref)
    $col = 0
    foreach ($ch in $Ref.ToUpperInvariant().ToCharArray()) {
        if ($ch -lt 'A' -or $ch -gt 'Z') { break }
        $col = $col * 26 + ([int]$ch - 64)
    }
    return ($col - 1)
}

function Get-WssXlsxNumberFormats {
    <# Style index (the s attribute of a cell) -> 'date', 'time', 'datetime', 'elapsed', 'percent' or $null. #>
    param($Zip)
    $kinds = @{}
    $xml = Get-WssZipEntryText $Zip 'xl/styles.xml'
    if (-not $xml) { return $kinds }
    $custom = @{}
    foreach ($m in [regex]::Matches($xml, '<numFmt\b[^>]*>')) {
        $id = [regex]::Match($m.Value, 'numFmtId="(\d+)"').Groups[1].Value
        $code = [System.Net.WebUtility]::HtmlDecode([regex]::Match($m.Value, 'formatCode="([^"]*)"').Groups[1].Value)
        if ($id) { $custom[[int]$id] = $code }
    }
    $xfs = [regex]::Match($xml, '(?s)<cellXfs\b[^>]*>(.*?)</cellXfs>').Groups[1].Value
    $i = 0
    foreach ($m in [regex]::Matches($xfs, '<xf\b[^>]*>')) {
        $id = 0
        [void][int]::TryParse([regex]::Match($m.Value, 'numFmtId="(\d+)"').Groups[1].Value, [ref]$id)
        $kind = $null
        if ($id -in 14, 15, 16, 17, 22) { $kind = $(if ($id -eq 22) { 'datetime' } else { 'date' }) }
        elseif ($id -in 18, 19, 20, 21, 45, 47) { $kind = 'time' }
        elseif ($id -eq 46) { $kind = 'elapsed' }
        elseif ($id -in 27..36 -or $id -in 50..58) { $kind = 'date' }
        elseif ($id -in 9, 10) { $kind = 'percent' }
        elseif ($custom.ContainsKey($id)) {
            # Ignore quoted literals, escapes, padding (_x, *x) and [Red]/[$-409] sections; [h]:mm is elapsed time.
            $raw = $custom[$id].Split(';')[0].ToLowerInvariant()
            $code = ($raw -replace '"[^"]*"', '' -replace '\\.', '' -replace '[_*].', '' -replace '\[[^\]]*\]', '')
            $hasTime = $code -match '[hs]' -or $raw -match '\[(h+|m+|s+)\]'
            $hasDate = $code -match '[dy]' -or ($code -match 'm' -and -not $hasTime)
            if ($raw -match '\[(h+|m+|s+)\]' -and -not ($code -match '[dy]')) { $kind = 'elapsed' }
            elseif ($hasDate -and $hasTime) { $kind = 'datetime' } elseif ($hasDate) { $kind = 'date' } elseif ($hasTime) { $kind = 'time' }
            elseif ($code -match '%') { $kind = 'percent' }
        }
        $kinds[$i] = $kind
        $i++
    }
    return $kinds
}

function Format-WssCellNumber {
    param([string]$Value, [string]$Kind, [bool]$Date1904)
    if (-not $Kind) { return $Value }
    $d = 0.0
    if (-not [double]::TryParse($Value, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$d)) { return $Value }
    $inv = [Globalization.CultureInfo]::InvariantCulture
    if ($Kind -eq 'percent') { return ($d * 100).ToString('0.##', $inv) + '%' }
    if ($Kind -eq 'elapsed') {
        # [h]:mm durations: 1.5 days are 36:00:00, not a date.
        $secs = [int64][Math]::Round([Math]::Abs($d) * 86400)
        $sign = $(if ($d -lt 0) { '-' } else { '' })
        return '{0}{1}:{2:00}:{3:00}' -f $sign, [Math]::Floor($secs / 3600), [Math]::Floor(($secs % 3600) / 60), ($secs % 60)
    }
    $base = $(if ($Date1904) { [datetime]'1904-01-01' } else { [datetime]'1899-12-30' })
    if ($d -lt 0 -or $d -gt 2958465) { return $Value }
    # Excel counts a 29 February 1900 that never existed; serials before it are one day later.
    if (-not $Date1904 -and $d -lt 60) { $d += 1 }
    # Whole seconds: serial numbers carry floating point noise (0.5 days may be 0.49999999).
    $dt = $base.AddSeconds([Math]::Round($d * 86400))
    switch ($Kind) {
        'time' { return $dt.ToString('HH:mm:ss', $inv) }
        'date' { if ($dt.TimeOfDay.Ticks -eq 0) { return $dt.ToString('yyyy-MM-dd', $inv) }; return $dt.ToString('yyyy-MM-dd HH:mm:ss', $inv) }
        default { return $dt.ToString('yyyy-MM-dd HH:mm:ss', $inv) }
    }
}

function Get-WssXlsxText {
    <# One block per sheet (workbook order, real names); one line per row: row number, then the cells by
       column, tab-separated. Empty cells keep their column, so values stay under their headers. #>
    param($Zip)
    $shared = New-Object System.Collections.ArrayList
    $ssXml = Get-WssZipEntryText $Zip 'xl/sharedStrings.xml'
    if ($ssXml) {
        foreach ($m in [regex]::Matches($ssXml, '(?s)<si\b[^>]*?(?:/>|>(.*?)</si>)')) {
            [void]$shared.Add([System.Net.WebUtility]::HtmlDecode(($m.Groups[1].Value -replace '(?s)<rPh\b.*?</rPh>', '' -replace '<[^>]+>', '')))
        }
    }
    $formats = Get-WssXlsxNumberFormats $Zip
    $sheets = @()
    $wb = Get-WssZipEntryText $Zip 'xl/workbook.xml'
    $date1904 = $false
    if ($wb) {
        $date1904 = $wb -match '<workbookPr\b[^>]*date1904="(1|true)"'
        $rels = Get-WssOoxmlRels $Zip 'xl/workbook.xml'
        foreach ($m in [regex]::Matches($wb, '<sheet\b[^>]*>')) {
            $name = [System.Net.WebUtility]::HtmlDecode([regex]::Match($m.Value, '\bname="([^"]*)"').Groups[1].Value)
            $part = $rels[[regex]::Match($m.Value, '\br:id="([^"]*)"').Groups[1].Value]
            $state = [regex]::Match($m.Value, '\bstate="([^"]*)"').Groups[1].Value
            if ($part -and $Zip.GetEntry($part)) { $sheets += @{ Name = $name; Part = $part; Hidden = ($state -match 'hidden') } }
        }
    }
    if ($sheets.Count -eq 0) {
        foreach ($part in Get-WssNumberedParts $Zip '^xl/worksheets/sheet(\d+)\.xml$') {
            $sheets += @{ Name = [IO.Path]::GetFileNameWithoutExtension($part); Part = $part; Hidden = $false }
        }
    }
    $sb = New-Object Text.StringBuilder
    foreach ($sheet in $sheets) {
        $xml = Get-WssZipEntryText $Zip $sheet.Part
        $header = "--- Sheet: $($sheet.Name)"
        if ($sheet.Hidden) { $header += ' (hidden)' }
        $dim = [regex]::Match("$xml", '<dimension\b[^>]*\bref="([^"]*)"').Groups[1].Value
        if ($dim) { $header += " [$dim]" }
        [void]$sb.AppendLine("$header ---")
        $rowNum = 0
        foreach ($row in [regex]::Matches("$xml", '(?s)<row\b([^>]*?)(?:/>|>(.*?)</row>)')) {
            $r = [regex]::Match($row.Groups[1].Value, '\br="(\d+)"').Groups[1].Value
            if ($r) { $rowNum = [int]$r } else { $rowNum++ }
            $cells = New-Object System.Collections.ArrayList
            $next = 0
            foreach ($c in [regex]::Matches($row.Groups[2].Value, '(?s)<c\b([^>]*?)(?:/>|>(.*?)</c>)')) {
                $attrs = $c.Groups[1].Value
                $inner = $c.Groups[2].Value
                $ref = [regex]::Match($attrs, '\br="([A-Za-z]+)\d*"').Groups[1].Value
                $col = $(if ($ref) { ConvertFrom-WssCellRef $ref } else { $next })
                $type = [regex]::Match($attrs, '\bt="([^"]*)"').Groups[1].Value
                $v = [System.Net.WebUtility]::HtmlDecode([regex]::Match($inner, '(?s)<v>(.*?)</v>').Groups[1].Value)
                switch ($type) {
                    's' { if ($v -match '^\d+$' -and [int]$v -lt $shared.Count) { $v = $shared[[int]$v] } }
                    'inlineStr' { $v = [System.Net.WebUtility]::HtmlDecode(($inner -replace '(?s)<rPh\b.*?</rPh>', '' -replace '<[^>]+>', '')) }
                    'b' { $v = $(if ($v -eq '1') { 'TRUE' } elseif ($v -eq '0') { 'FALSE' } else { $v }) }
                    { $_ -in 'str', 'e' } { }
                    default {
                        $s = [regex]::Match($attrs, '\bs="(\d+)"').Groups[1].Value
                        if ($v -and $s -and $formats.ContainsKey([int]$s)) { $v = Format-WssCellNumber $v $formats[[int]$s] $date1904 }
                    }
                }
                $v = ($v -replace '[\t\r\n]+', ' ')
                while ($cells.Count -lt $col) { [void]$cells.Add('') }
                if ($cells.Count -eq $col) { [void]$cells.Add($v) } else { $cells[$col] = $v }
                $next = $col + 1
            }
            while ($cells.Count -gt 0 -and $cells[$cells.Count - 1] -eq '') { $cells.RemoveAt($cells.Count - 1) }
            if ($cells.Count -eq 0) { continue }
            [void]$sb.AppendLine("$rowNum`t" + ($cells -join "`t"))
        }
    }
    return $sb.ToString().Trim()
}

function Get-WssDocumentText {
    <# Extracts readable text from plain-text files, Office Open XML documents and, through the Windows
       IFilter of the file type, other formats such as PDF, .doc, .rtf or .msg. #>
    param([string]$LiteralPath, [hashtable]$Config = @{})
    $ext = [IO.Path]::GetExtension($LiteralPath).ToLowerInvariant()
    if ($ext -in @('.docx', '.docm', '.dotx', '.dotm', '.pptx', '.pptm', '.ppsx', '.potx', '.xlsx', '.xlsm', '.xltx', '.xltm')) {
        Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        $fs = [IO.File]::Open($LiteralPath, 'Open', 'Read', 'ReadWrite')
        try {
            try { $zip = New-Object IO.Compression.ZipArchive($fs, [IO.Compression.ZipArchiveMode]::Read) }
            catch { throw "'$LiteralPath' is not a valid Office document (it may be password-protected or damaged)." }
            try {
                if ($ext -like '.do*') { return Get-WssDocxText $zip }
                if ($ext -like '.p*') { return Get-WssPptxText $zip }
                return Get-WssXlsxText $zip
            } finally { $zip.Dispose() }
        } finally { $fs.Dispose() }
    }
    $useIFilter = ConvertTo-WssBool $Config.UseIFilter $true
    $filterTimeout = ConvertTo-WssInt $Config.FilterTimeout 60 1 600
    # Formats that look like text but read far better through their filter (RTF control words, MIME parts).
    if ($useIFilter -and $ext -in $script:IFilterFirstExtensions) {
        $t = Get-WssIFilterText -LiteralPath $LiteralPath -Optional -TimeoutSeconds $filterTimeout
        if ($null -ne $t) { return $t }
    }
    $bytes = [IO.File]::ReadAllBytes($LiteralPath)
    $probe = [Math]::Min($bytes.Length, 8000)
    $binary = $false
    for ($i = 0; $i -lt $probe; $i++) {
        if ($bytes[$i] -eq 0) {
            # UTF-16 files contain NULs too; detect by BOM.
            if ($bytes.Length -ge 2 -and (($bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) -or ($bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF))) { break }
            $binary = $true; break
        }
    }
    if ($binary -or ($bytes.Length -ge 5 -and [Text.Encoding]::ASCII.GetString($bytes, 0, 5) -eq '%PDF-')) {
        $plain = "Text files and .docx/.xlsx/.pptx can always be read; use copy_file to work with this file in the workspace."
        if (-not $useIFilter) { throw "'$LiteralPath' is a binary file ($ext) and reading other formats through Windows filters is disabled (useIFilter). $plain" }
        if (-not (Test-WssIsWindows) -and -not $script:IFilterExtractor) { throw "'$LiteralPath' looks like a binary file ($ext). $plain" }
        return Get-WssIFilterText -LiteralPath $LiteralPath -TimeoutSeconds $filterTimeout
    }
    $sr = New-Object IO.StreamReader((New-Object IO.MemoryStream(, $bytes)), (New-Object Text.UTF8Encoding($false)), $true)
    try { return $sr.ReadToEnd() } finally { $sr.Dispose() }
}

# ---------------------------------------------------------------------------
# Windows filters (IFilter): the components Windows Search itself uses to read PDF, .doc, .rtf, .msg, ...
# ---------------------------------------------------------------------------

$script:IFilterFirstExtensions = @('.rtf', '.eml', '.mht', '.mhtml')
$script:IFilterMaxChars = 5000000
$script:IFilterExtractor = $null   # scriptblock: param($Path, $MaxChars, $TimeoutMs) -> @{ Text; NoFilter; HResult; Truncated } (tests)
$script:IFilterLoaded = $false
# C# 5 (Windows PowerShell 5.1 compiles with the .NET Framework compiler).
$script:IFilterSource = @'
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace WssIFilter {
    [StructLayout(LayoutKind.Sequential)]
    public struct PROPSPEC { public uint ulKind; public IntPtr data; }
    [StructLayout(LayoutKind.Sequential)]
    public struct FULLPROPSPEC { public Guid guidPropSet; public PROPSPEC psProperty; }
    [StructLayout(LayoutKind.Sequential)]
    public struct STAT_CHUNK {
        public uint idChunk; public int breakType; public int flags; public uint locale;
        public FULLPROPSPEC attribute; public uint idChunkSource; public uint cwcStartSource; public uint cwcLenSource;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct FILTERREGION { public uint idChunk; public uint cwcStart; public uint cwcExtent; }

    [ComImport, Guid("89BCB740-6119-101A-BCB7-00DD010655AF"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IFilter {
        [PreserveSig] int Init(uint grfFlags, uint cAttributes, IntPtr aAttributes, out uint pdwFlags);
        [PreserveSig] int GetChunk(out STAT_CHUNK pStat);
        [PreserveSig] int GetText(ref uint pcwcBuffer, IntPtr awcBuffer);
        [PreserveSig] int GetValue(out IntPtr ppPropValue);
        [PreserveSig] int BindRegion(FILTERREGION origPos, ref Guid riid, out IntPtr ppunk);
    }

    public class Result {
        public string Text;
        public bool NoFilter;
        public int HResult;
        public bool Truncated;
    }

    public static class Extractor {
        [DllImport("query.dll", CharSet = CharSet.Unicode)]
        static extern int LoadIFilter(string pwcsPath, IntPtr pUnkOuter, out IntPtr ppIUnk);

        const int FILTER_E_END_OF_CHUNKS = unchecked((int)0x80041700);
        const int FILTER_E_NO_MORE_TEXT = unchecked((int)0x80041701);
        const int FILTER_E_NO_TEXT = unchecked((int)0x80041705);
        const int FILTER_E_EMBEDDING_UNAVAILABLE = unchecked((int)0x80041707);
        const int FILTER_E_LINK_UNAVAILABLE = unchecked((int)0x80041708);
        const int FILTER_S_LAST_TEXT = 0x00041709;
        const int CHUNK_TEXT = 1;
        const uint BUFFER_CHARS = 8192;
        static readonly Guid StorageProps = new Guid("B725F130-47EF-101A-A5F1-02608C9EEBAC");

        // Runs the filter on its own STA thread (some filters require STA) and gives up after timeoutMs,
        // so a hanging filter can't block the server.
        public static Result Extract(string path, int maxChars, int timeoutMs) {
            Result result = null;
            Exception error = null;
            Thread t = new Thread(delegate() {
                try { result = Run(path, maxChars); } catch (Exception e) { error = e; }
            });
            t.IsBackground = true;
            t.SetApartmentState(ApartmentState.STA);
            t.Start();
            if (!t.Join(timeoutMs)) throw new TimeoutException("The Windows filter did not finish within " + (timeoutMs / 1000) + " seconds.");
            if (error != null) throw error;
            return result;
        }

        static Result Run(string path, int maxChars) {
            Result r = new Result();
            IntPtr unk;
            int hr = LoadIFilter(path, IntPtr.Zero, out unk);
            if (hr != 0 || unk == IntPtr.Zero) { r.NoFilter = true; r.HResult = hr; return r; }
            IFilter filter = null;
            IntPtr buf = Marshal.AllocCoTaskMem((int)(BUFFER_CHARS + 2) * 2);
            try {
                filter = (IFilter)Marshal.GetObjectForIUnknown(unk);
                uint flags;
                // canonical paragraphs, hard line breaks, canonical hyphens and spaces, index attributes
                hr = filter.Init(1 | 2 | 4 | 8 | 16, 0, IntPtr.Zero, out flags);
                if (hr < 0) { r.HResult = hr; return r; }
                StringBuilder sb = new StringBuilder();
                while (!r.Truncated) {
                    STAT_CHUNK chunk;
                    hr = filter.GetChunk(out chunk);
                    if (hr == FILTER_E_END_OF_CHUNKS) break;
                    if (hr == FILTER_E_EMBEDDING_UNAVAILABLE || hr == FILTER_E_LINK_UNAVAILABLE) continue;
                    if (hr < 0) { if (sb.Length == 0) r.HResult = hr; break; }
                    if ((chunk.flags & CHUNK_TEXT) == 0) continue;
                    // Only the document body (System.Contents), not title, author and other properties.
                    if (chunk.attribute.guidPropSet == StorageProps && chunk.attribute.psProperty.ulKind == 1 && chunk.attribute.psProperty.data.ToInt64() != 19) continue;
                    if (sb.Length > 0) {
                        char last = sb[sb.Length - 1];
                        if (chunk.breakType == 3 || chunk.breakType == 4) { if (last != '\n') sb.Append('\n'); }
                        else if (chunk.breakType == 1 || chunk.breakType == 2) { if (!char.IsWhiteSpace(last)) sb.Append(' '); }
                    }
                    while (true) {
                        uint len = BUFFER_CHARS;
                        hr = filter.GetText(ref len, buf);
                        if (hr < 0) break;
                        if (len > BUFFER_CHARS) len = BUFFER_CHARS;
                        if (len > 0) sb.Append(Marshal.PtrToStringUni(buf, (int)len));
                        if (sb.Length >= maxChars) { r.Truncated = true; break; }
                        if (hr == FILTER_S_LAST_TEXT) break;
                    }
                }
                if (sb.Length > maxChars) sb.Length = maxChars;
                r.Text = sb.ToString().Replace("\r\n", "\n").Replace('\r', '\n');
                return r;
            } finally {
                Marshal.FreeCoTaskMem(buf);
                if (filter != null) Marshal.ReleaseComObject(filter);
                Marshal.Release(unk);
            }
        }
    }
}
'@

function Get-WssIFilterText {
    <# Text of a file through the IFilter registered for its type on this PC. With -Optional, returns $null
       instead of failing (used for text formats that also read acceptably as plain text). #>
    param([string]$LiteralPath, [switch]$Optional, [int]$TimeoutSeconds = 60)
    $ext = [IO.Path]::GetExtension($LiteralPath).ToLowerInvariant()
    $copyHint = 'Use copy_file to work with the file in the workspace instead.'
    try {
        if ($script:IFilterExtractor) {
            $r = & $script:IFilterExtractor $LiteralPath $script:IFilterMaxChars ($TimeoutSeconds * 1000)
        } else {
            if (-not (Test-WssIsWindows)) { throw 'Windows filters are only available on Windows.' }
            if (-not $script:IFilterLoaded) {
                Add-Type -TypeDefinition $script:IFilterSource -Language CSharp -ErrorAction Stop
                $script:IFilterLoaded = $true
            }
            $r = [WssIFilter.Extractor]::Extract($LiteralPath, $script:IFilterMaxChars, $TimeoutSeconds * 1000)
        }
    } catch {
        $inner = $_.Exception
        while ($inner.InnerException) { $inner = $inner.InnerException }
        Write-WssLog "IFilter for '$LiteralPath' failed: $($inner.Message)"
        if ($Optional) { return $null }
        throw "Reading '$LiteralPath' through its Windows filter failed: $($inner.Message) $copyHint"
    }
    if ($r.NoFilter) {
        if ($Optional) { return $null }
        $pdf = $(if ($ext -eq '.pdf') { ' PDF text needs a PDF filter, which Adobe Acrobat Reader and other PDF readers install.' } else { '' })
        throw "No Windows filter (IFilter) for $ext files is installed on this PC, so the text of '$LiteralPath' can't be read here.$pdf $copyHint"
    }
    $text = "$($r.Text)"
    if ($r.HResult -ne 0 -and -not $text) {
        if ($Optional) { return $null }
        throw ("The Windows filter for $ext files could not read '$LiteralPath' (error 0x{0:X8}); it may be password-protected or damaged. $copyHint" -f $r.HResult)
    }
    if (-not $text.Trim()) {
        if ($Optional) { return $null }
        throw "No text found in '$LiteralPath'. It may be a scanned document or an image without a text layer. $copyHint"
    }
    if ($r.Truncated) { $text += "`n[... text truncated after $($script:IFilterMaxChars) characters]" }
    return $text
}

# ASCII source only: Windows PowerShell 5.1 reads BOM-less scripts in the ANSI code page.
$script:Ellipsis = [string][char]0x2026

function New-WssFindRegex {
    <# Case-insensitive regex for "phrase" or "a OR b"; whitespace in a phrase also matches line breaks. #>
    param([string]$Find, [switch]$Prefix)
    $alts = @()
    foreach ($part in ($Find -split '\s+OR\s+')) {
        $p = $part.Trim().Trim('"').Trim()
        if (-not $p) { continue }
        $rx = ([regex]::Escape($p) -replace '(\\ |\\t|\\n|\\r)+', '\s+')
        if ($Prefix -and $p -match '^\w') { $rx = '\b' + $rx }
        $alts += $rx
    }
    if ($alts.Count -eq 0) { return $null }
    return New-Object regex(($alts -join '|'), ([Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [Text.RegularExpressions.RegexOptions]::CultureInvariant))
}

function Find-WssPassages {
    <# Passages around each match: the matching line plus $Context lines before and after; overlapping
       passages are merged. Very long lines (one-line PDFs, spreadsheets) are cut around the match. #>
    param([string]$Text, [string]$Find, [int]$Context = 2, [int]$MaxPassages = 20, [int]$MaxPassageChars = 1500)
    $rx = New-WssFindRegex $Find
    if (-not $rx) { throw 'find must contain a word or phrase.' }
    $hits = $rx.Matches($Text)
    $starts = New-Object System.Collections.Generic.List[int]
    $starts.Add(0)
    for ($i = $Text.IndexOf("`n"); $i -ge 0; $i = $Text.IndexOf("`n", $i + 1)) { $starts.Add($i + 1) }
    $lineOf = {
        param([int]$pos)
        $idx = $starts.BinarySearch($pos)
        if ($idx -lt 0) { $idx = (-bnot $idx) - 1 }
        return $idx
    }
    $lineEnd = {
        param([int]$line)
        if ($line + 1 -lt $starts.Count) { return $starts[$line + 1] - 1 }
        return $Text.Length
    }
    $passages = New-Object System.Collections.ArrayList
    $cur = $null
    $truncated = $false
    foreach ($m in $hits) {
        $line = & $lineOf $m.Index
        $first = [Math]::Max(0, $line - $Context)
        $last = [Math]::Min($starts.Count - 1, (& $lineOf ($m.Index + [Math]::Max(0, $m.Length - 1))) + $Context)
        $from = $starts[$first]
        $to = & $lineEnd $last
        $cut = $false
        if ($to - $from -gt $MaxPassageChars) {
            $half = [int](($MaxPassageChars - $m.Length) / 2)
            $from = [Math]::Max($starts[$line], $m.Index - [Math]::Max(100, $half))
            $to = [Math]::Min($Text.Length, $m.Index + $m.Length + [Math]::Max(100, $half))
            $cut = $true
        }
        if ($cur -and $from -le $cur.To + 1 -and ($to - $cur.From) -le $MaxPassageChars * 2) {
            if ($to -gt $cur.To) { $cur.To = $to }
            $cur.Cut = $cur.Cut -or $cut
            continue
        }
        if ($passages.Count -ge $MaxPassages) { $truncated = $true; break }
        $cur = @{ From = $from; To = $to; Line = (& $lineOf $from) + 1; Cut = $cut }
        [void]$passages.Add($cur)
    }
    $out = @()
    foreach ($p in $passages) {
        $t = $Text.Substring($p.From, $p.To - $p.From).Trim("`r", "`n") -replace "`r", ''
        if ($p.Cut) {
            if ($p.From -gt 0 -and $Text[$p.From - 1] -ne "`n") { $t = $script:Ellipsis + $t }
            if ($p.To -lt $Text.Length -and $Text[$p.To] -ne "`n") { $t += $script:Ellipsis }
        }
        $out += [ordered]@{ line = $p.Line; offset = $p.From; text = $t }
    }
    return @{ MatchCount = $hits.Count; Passages = $out; Truncated = $truncated }
}

$script:SnippetSkipExtensions = @('.jpg', '.jpeg', '.png', '.gif', '.bmp', '.tif', '.tiff', '.heic', '.webp', '.ico', '.svgz',
    '.mp3', '.wav', '.wma', '.m4a', '.flac', '.mp4', '.mov', '.avi', '.mkv', '.wmv', '.zip', '.7z', '.rar', '.gz', '.tar',
    '.cab', '.iso', '.vhd', '.vhdx', '.exe', '.dll', '.msi', '.sys', '.bin', '.dat', '.db', '.mdb', '.accdb', '.pst', '.ost')

function Add-WssSnippets {
    <# Adds "snippet" (text around the first query match) to the first results by reading their text,
       within a time budget. The index itself has no reliable snippet column for remote queries. #>
    param($Results, [string]$Query, [hashtable]$Config, $Targets, $Policy, [int]$Max = 10, [int]$BudgetMs = 15000)
    $words = @(Get-WssQueryTerms $Query | Where-Object { -not $_.Exclude } | ForEach-Object { $_.Text })
    if ($words.Count -eq 0) { return 0 }
    $rx = New-WssFindRegex ($words -join ' OR ') -Prefix
    # A slow filter (large PDF) must not use up the whole budget.
    $cfg = $Config.Clone()
    $cfg.FilterTimeout = [Math]::Min(10, (ConvertTo-WssInt $Config.FilterTimeout 60 1 600))
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $done = 0
    foreach ($res in @($Results | Select-Object -First $Max)) {
        if ($sw.ElapsedMilliseconds -gt $BudgetMs) { break }
        if (-not $res.path) { continue }
        $ext = [IO.Path]::GetExtension("$($res.path)").ToLowerInvariant()
        if ($ext -in $script:SnippetSkipExtensions -or ($res.Contains('size') -and $res.size -gt 20MB)) { continue }
        try {
            Assert-WssAllowed $res.path $Policy -CheckFinalPath
            $text = Get-WssDocumentText -LiteralPath $res.path -Config $cfg
        } catch { continue }
        $m = $rx.Match($text)
        if (-not $m.Success) { continue }
        $from = [Math]::Max(0, $m.Index - 120)
        $to = [Math]::Min($text.Length, $m.Index + $m.Length + 180)
        $s = ($text.Substring($from, $to - $from) -replace '\s+', ' ').Trim()
        if ($from -gt 0) { $s = $script:Ellipsis + $s }
        if ($to -lt $text.Length) { $s += $script:Ellipsis }
        $res.snippet = $s
        $done++
    }
    return $done
}

function Read-WssFile {
    param([hashtable]$Arguments, [hashtable]$Config = (Get-WssConfig), $Targets = $null)
    if ($null -eq $Targets) { $Targets = @(Get-WssTargets -Config $Config) }
    $unc = Resolve-WssPath $Arguments.path $Targets
    Assert-WssAllowed $unc (Get-WssPolicy -Config $Config -Targets $Targets) -CheckFinalPath
    if (-not (Test-Path -LiteralPath $unc -PathType Leaf)) { throw "File not found: $unc" }
    $item = Get-Item -LiteralPath $unc
    $maxBytes = 50MB
    if ($item.Length -gt $maxBytes) { throw "File is too large to read ($($item.Length) bytes)." }
    $text = Get-WssDocumentText -LiteralPath $unc -Config $Config
    if ("$($Arguments.find)".Trim()) {
        $found = Find-WssPassages -Text $text -Find "$($Arguments.find)" `
            -Context (ConvertTo-WssInt $Arguments.context 2 0 20) -MaxPassages (ConvertTo-WssInt $Arguments.max_matches 20 1 200)
        $out = [ordered]@{
            path        = $unc
            size_bytes  = [int64]$item.Length
            modified    = ConvertTo-WssIso $item.LastWriteTime
            total_chars = $text.Length
            find        = "$($Arguments.find)"
            match_count = $found.MatchCount
        }
        $drivePath = Convert-WssUncToDrivePath $unc $Targets
        if ($drivePath) { $out.drive_path = $drivePath }
        $out.passages = @($found.Passages)
        $out.passages_truncated = $found.Truncated
        if ($found.MatchCount -gt 0) { $out.hint = 'Each passage starts at "offset" (line "line"); call read_file with that offset to read on from there.' }
        else { $out.hint = 'No matches. Matching ignores case and line breaks; try fewer or other words, or "a OR b".' }
        return $out
    }
    $offset = ConvertTo-WssInt $Arguments.offset 0 0 ([int]::MaxValue)
    $max = ConvertTo-WssInt $Arguments.max_chars 20000 1 200000
    $total = $text.Length
    if ($offset -gt $total) { $offset = $total }
    $len = [Math]::Min($max, $total - $offset)
    $chunk = $text.Substring($offset, $len)
    $out = [ordered]@{
        path          = $unc
        size_bytes    = [int64]$item.Length
        modified      = ConvertTo-WssIso $item.LastWriteTime
        total_chars   = $total
        offset        = $offset
        returned      = $len
        truncated     = (($offset + $len) -lt $total)
    }
    $drivePath = Convert-WssUncToDrivePath $unc $Targets
    if ($drivePath) { $out.drive_path = $drivePath }
    if ($out.truncated) { $out.next_offset = $offset + $len }
    $out.content = $chunk
    return $out
}

function Get-WssDirectoryListing {
    param([hashtable]$Arguments, [hashtable]$Config = (Get-WssConfig), $Targets = $null)
    if ($null -eq $Targets) { $Targets = @(Get-WssTargets -Config $Config) }
    $unc = Resolve-WssPath $Arguments.path $Targets
    $policy = Get-WssPolicy -Config $Config -Targets $Targets
    Assert-WssAllowed $unc $policy -CheckFinalPath
    if (-not (Test-Path -LiteralPath $unc -PathType Container)) { throw "Directory not found: $unc" }
    $limit = ConvertTo-WssInt $Arguments.max_entries 200 1 2000
    $entries = @()
    $count = 0
    $hidden = 0
    $truncated = $false
    foreach ($i in Get-ChildItem -LiteralPath $unc -Force -ErrorAction SilentlyContinue) {
        if (Test-WssBlocked ($unc.TrimEnd('\') + '\' + $i.Name) $policy) { $hidden++; continue }
        if ($count -ge $limit) { $truncated = $true; break }
        $count++
        $e = [ordered]@{ name = $i.Name; type = $(if ($i.PSIsContainer) { 'directory' } else { 'file' }) }
        if (-not $i.PSIsContainer) { $e.size = [int64]$i.Length }
        $e.modified = ConvertTo-WssIso $i.LastWriteTime
        $entries += $e
    }
    $out = [ordered]@{ path = $unc }
    $drivePath = Convert-WssUncToDrivePath $unc $Targets
    if ($drivePath) { $out.drive_path = $drivePath }
    $out.entries = @($entries)
    $out.truncated = $truncated
    $out.hidden_by_policy = $hidden
    return $out
}

# ---------------------------------------------------------------------------
# Access policy: wildcard deny rules (gitignore-style) from several sources
# ---------------------------------------------------------------------------

$script:PolicyFileName = '.claude-policy'
$script:BuiltinDenyPatterns = @(
    '**\$RECYCLE.BIN',
    '**\System Volume Information',
    '**\*.kdbx',
    '**\*.kdb',
    '**\*.pfx',
    '**\*.p12',
    '**\~$*'
)
$script:PolicyCache = @{}
$script:RegistryPolicyProvider = $null   # scriptblock: -> array of patterns (tests / fake backend)
$script:PolicyFileReader = $null         # scriptblock: param($ShareUnc) -> @{ Status='none'|'ok'|'error'; Content; Error }
$script:UserPolicyTemplate = @'
# .claude-policy - your own blocked paths for the windows-server-search Claude plugin.
# Same syntax as the .claude-policy files in the root of a share; here every rule applies to ALL shares.
# Claude can neither find (search), list, read nor copy matching files and folders. Changes apply immediately.
#
# Syntax (like .gitignore, case-insensitive, / and \ both work):
#   name          matches a file or folder with that name at any depth in every share
#   /name         only directly in the root of a share
#   a/b           a path relative to the root of a share (anchored because it contains a slash)
#   *             any characters within one name     ?   one character
#   **            any number of folders
#   \\fs01\hr     a specific server or share (also \\*\hr, \\fs01\projects\*\Contracts)
#   Z:\Finance    a path on a mapped network drive
# A matching folder blocks everything below it. Lines starting with # are comments.
# "!" negations are not supported (rules can only block, never re-allow).
#
# Examples:
#   Personal/
#   /HR
#   *.kdbx
#   \\fs01\projects\*\Contracts

'@
$script:FinalPathTypeLoaded = $false

function Get-WssCanonicalUnc {
    <#
      Normalises a UNC path for policy matching: NetBIOS host name, lower case, '.'/'..' resolved,
      trailing dots/spaces and alternate data streams removed, optionally 8.3 short names expanded.
    #>
    param([string]$Path, [switch]$ExpandShortNames)
    $u = ConvertFrom-WssUncPath $Path
    if (-not $u) { return $null }
    $hostName = (Get-WssQueryMachine $u.Host $true)
    $raw = @()
    if ($u.Share) { $raw += $u.Share }
    if ($u.Rest) { $raw += ($u.Rest -split '\\') }
    $segments = New-Object System.Collections.ArrayList
    foreach ($seg in $raw) {
        $s = $seg
        $colon = $s.IndexOf(':')
        if ($colon -ge 0) { $s = $s.Substring(0, $colon) }
        if ($s.Trim() -eq '.') { continue }
        if ($s.Trim() -eq '..') { if ($segments.Count -gt 1) { $segments.RemoveAt($segments.Count - 1) }; continue }
        $s = $s.TrimEnd('.', ' ')
        if ($s -eq '') { continue }
        if ($ExpandShortNames -and $segments.Count -ge 1 -and $s -match '~\d' -and (Test-WssIsWindows)) {
            try {
                $parent = "\\$($u.Host)\" + ($segments -join '\')
                $found = @([IO.Directory]::GetFileSystemEntries($parent, $s))
                if ($found.Count -eq 1) { $s = [IO.Path]::GetFileName($found[0]) }
            } catch { }
        }
        [void]$segments.Add($s)
    }
    $out = "\\$hostName"
    if ($segments.Count -gt 0) { $out += '\' + ($segments -join '\') }
    return $out.ToLowerInvariant()
}

function ConvertTo-WssGlobRegex {
    <# Converts a glob (separator '\') into a regex fragment: ** any depth, * and ? within one name. #>
    param([string]$Glob)
    $g = $Glob.ToLowerInvariant()
    $sb = New-Object Text.StringBuilder
    $i = 0
    while ($i -lt $g.Length) {
        $c = $g[$i]
        if ($c -eq '*') {
            if ($i + 1 -lt $g.Length -and $g[$i + 1] -eq '*') {
                $atStart = ($i -eq 0 -or $g[$i - 1] -eq '\')
                $i += 2
                if ($atStart -and $i -lt $g.Length -and $g[$i] -eq '\') { [void]$sb.Append('(?:.*\\)?'); $i++; continue }
                [void]$sb.Append('.*'); continue
            }
            [void]$sb.Append('[^\\]*'); $i++; continue
        }
        if ($c -eq '?') { [void]$sb.Append('[^\\]'); $i++; continue }
        [void]$sb.Append([regex]::Escape([string]$c)); $i++
    }
    return $sb.ToString()
}

function New-WssPolicyRule {
    <#
      Builds a deny rule. Without -ShareRoot (global sources): \\server\share\..., drive paths (Z:\...)
      or floating patterns (match at any depth on any share). With -ShareRoot (a share's .claude-policy):
      gitignore semantics - patterns with a leading or middle '\' are anchored at the share root,
      others match at any depth inside the share. A matching folder blocks everything below it.
      With -AnyShare (the user's .claude-policy): the same gitignore semantics relative to every share;
      server paths (\\server\...) and drive paths (Z:\...) keep their global meaning.
    #>
    param([string]$Pattern, [string]$Source, [string]$ShareRoot, $Targets = @(), [switch]$AnyShare)
    $p = $Pattern.Trim() -replace '/', '\'
    if (-not $p) { throw 'empty pattern' }
    if ($p -match '[<>|"\x00-\x1f]') { throw "invalid characters in pattern '$Pattern'" }
    $relative = $ShareRoot -or ($AnyShare -and -not $p.StartsWith('\\') -and $p -notmatch '^[A-Za-z]:')
    if ($relative) {
        $anchored = $false
        if ($p.StartsWith('\')) { $anchored = $true; $p = $p.TrimStart('\') }
        $p = $p.TrimEnd('\')
        if ($p.Contains('\')) { $anchored = $true }
        if (-not $p) { throw "pattern '$Pattern' matches the whole share; remove the share instead" }
        if ($ShareRoot) { $body = [regex]::Escape($ShareRoot.ToLowerInvariant()) + '\\' } else { $body = '\\\\[^\\]+\\[^\\]+\\' }
        if ($anchored) { $body += (ConvertTo-WssGlobRegex $p) } else { $body += '(?:.*\\)?' + (ConvertTo-WssGlobRegex $p) }
    } else {
        if ($p -match '^([A-Za-z]:)(\\.*)?$') {
            $drive = $Matches[1].ToUpperInvariant()
            $rest = ''; if ($Matches.Count -gt 2 -and $Matches[2]) { $rest = $Matches[2] }
            $unc = $null
            foreach ($srv in $Targets) { foreach ($sh in $srv.Shares) { if ($sh.Drives -contains $drive) { $unc = $sh.Unc } } }
            if (-not $unc) { throw "drive $drive in pattern '$Pattern' is not a mapped drive of a known server" }
            $p = $unc + $rest
        }
        $p = $p.TrimEnd('\')
        if ($p.StartsWith('\\')) {
            $m = [regex]::Match($p, '^\\\\([^\\]+)(.*)$')
            $hostPart = $m.Groups[1].Value
            if ($hostPart -notmatch '[*?]') { $hostPart = Get-WssQueryMachine $hostPart $true }
            $body = '\\\\' + (ConvertTo-WssGlobRegex $hostPart) + (ConvertTo-WssGlobRegex $m.Groups[2].Value)
        } else {
            $p = $p.TrimStart('\')
            if (-not $p) { throw 'empty pattern' }
            $body = '\\\\[^\\]+\\(?:.*\\)?' + (ConvertTo-WssGlobRegex $p)
        }
    }
    $regex = '^' + $body + '(?:\\.*)?$'
    return @{
        Pattern = $Pattern.Trim()
        Source  = $Source
        Regex   = New-Object regex($regex, ([Text.RegularExpressions.RegexOptions]'IgnoreCase, CultureInvariant'))
    }
}

function ConvertFrom-WssPolicyText {
    <# Parses a gitignore-style .claude-policy file. Returns @{ Patterns; Warnings }. Throws on invalid content. #>
    param([string]$Text)
    $patterns = @()
    $warnings = @()
    $n = 0
    foreach ($line in ($Text -split "`r?`n")) {
        $n++
        $l = $line.Trim()
        if ($n -eq 1) { $l = $l.TrimStart([char]0xFEFF) }
        if (-not $l -or $l.StartsWith('#')) { continue }
        if ($l.StartsWith('!')) { $warnings += "line ${n}: negation ('!') is not supported and was ignored"; continue }
        if ($l -match '[<>|"\x00-\x1f]') { throw "line ${n}: invalid characters in '$l'" }
        $patterns += $l
    }
    return @{ Patterns = $patterns; Warnings = $warnings }
}

function Get-WssRegistryDenyPatterns {
    <# Deny patterns pushed by IT via Group Policy / Intune (users cannot write these keys). #>
    if ($script:RegistryPolicyProvider) { return @(& $script:RegistryPolicyProvider) }
    if (-not (Test-WssIsWindows)) { return @() }
    $out = @()
    foreach ($key in @('HKLM:\SOFTWARE\Policies\WindowsServerSearchMcp', 'HKCU:\SOFTWARE\Policies\WindowsServerSearchMcp')) {
        try {
            $v = (Get-ItemProperty -LiteralPath $key -Name DenyPaths -ErrorAction Stop).DenyPaths
            foreach ($x in @($v)) { $out += @(Split-WssList "$x" '[;\r\n]+') }
        } catch { }
    }
    return $out
}

function Read-WssSharePolicy {
    <# Reads <share>\.claude-policy (cached). Returns @{ Status='none'|'ok'|'error'; Content; Error }. #>
    param([string]$ShareUnc, [int]$TtlSeconds = 300)
    $key = $ShareUnc.ToLowerInvariant()
    $cached = $script:PolicyCache[$key]
    if ($cached -and ((Get-Date) - $cached.Time).TotalSeconds -lt $TtlSeconds) { return $cached.Value }
    if ($script:PolicyFileReader) {
        $value = & $script:PolicyFileReader $ShareUnc
    } elseif (-not (Test-WssIsWindows)) {
        $value = @{ Status = 'none' }
    } else {
        $file = $ShareUnc.TrimEnd('\') + '\' + $script:PolicyFileName
        try {
            if ([IO.File]::Exists($file)) {
                $info = New-Object IO.FileInfo($file)
                if ($info.Length -gt 1MB) { $value = @{ Status = 'error'; Error = 'policy file is larger than 1 MB' } }
                else { $value = @{ Status = 'ok'; Content = [IO.File]::ReadAllText($file) } }
            } elseif ([IO.Directory]::Exists($ShareUnc)) {
                $value = @{ Status = 'none' }
            } else {
                $value = @{ Status = 'error'; Error = 'share not reachable, so its policy file could not be checked' }
            }
        } catch {
            $value = @{ Status = 'error'; Error = $_.Exception.Message }
        }
    }
    $script:PolicyCache[$key] = @{ Time = (Get-Date); Value = $value }
    return $value
}

function Read-WssUserPolicy {
    <# Reads the user's own .claude-policy (next to the config file). Returns @{ Status='none'|'ok'|'error'; Content; Error }. #>
    param([string]$Path)
    if (-not $Path) { return @{ Status = 'none' } }
    try {
        if (-not [IO.File]::Exists($Path)) { return @{ Status = 'none' } }
        if ((New-Object IO.FileInfo($Path)).Length -gt 1MB) { return @{ Status = 'error'; Error = 'policy file is larger than 1 MB' } }
        return @{ Status = 'ok'; Content = [IO.File]::ReadAllText($Path) }
    } catch {
        return @{ Status = 'error'; Error = $_.Exception.Message }
    }
}

function Initialize-WssUserPolicy {
    <# Creates the user's .claude-policy (comments only, no rules) if it doesn't exist yet, so it is easy to find. #>
    param([hashtable]$Config)
    $path = $Config.PolicyFile
    if (-not $path -or (Test-Path -LiteralPath $path)) { return $false }
    try {
        $dir = [IO.Path]::GetDirectoryName($path)
        if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
        [IO.File]::WriteAllText($path, ($script:UserPolicyTemplate -replace "`r?`n", "`r`n"), (New-Object Text.UTF8Encoding($false)))
        Write-WssLog "created $path"
        return $true
    } catch {
        Write-WssLog "could not create '$path': $($_.Exception.Message)"
        return $false
    }
}

function Get-WssPolicy {
    <# Combines all deny sources. Sources can only add rules; a broken share policy blocks that share (fail closed). #>
    param([hashtable]$Config, $Targets)
    $rules = New-Object System.Collections.ArrayList
    $warnings = New-Object System.Collections.ArrayList
    $blocked = New-Object System.Collections.ArrayList
    $files = New-Object System.Collections.ArrayList
    $counts = [ordered]@{ 'built-in' = 0; 'group-policy' = 0; 'plugin-config' = 0; 'user-policy' = 0; 'share-policy' = 0 }

    $global = @()
    foreach ($p in $script:BuiltinDenyPatterns) { $global += , @($p, 'built-in') }
    foreach ($p in @(Get-WssRegistryDenyPatterns)) { $global += , @($p, 'group-policy') }
    foreach ($p in @($Config.Deny)) { if ($p) { $global += , @($p, 'plugin-config') } }
    foreach ($g in $global) {
        try {
            [void]$rules.Add((New-WssPolicyRule -Pattern $g[0] -Source $g[1] -Targets $Targets))
            $counts[$g[1]]++
        } catch {
            [void]$warnings.Add("$($g[1]) pattern '$($g[0])' ignored: $($_.Exception.Message)")
        }
    }

    # The user's own .claude-policy: gitignore style like a share's, applied to every share.
    $userFile = $Config.PolicyFile
    $state = Read-WssUserPolicy $userFile
    $reason = $null
    if ($state.Status -eq 'ok') {
        try {
            $parsed = ConvertFrom-WssPolicyText $state.Content
            $n = 0
            foreach ($p in $parsed.Patterns) {
                try {
                    [void]$rules.Add((New-WssPolicyRule -Pattern $p -Source 'user-policy' -Targets $Targets -AnyShare))
                    $n++
                } catch {
                    [void]$warnings.Add("$userFile pattern '$p' ignored: $($_.Exception.Message)")
                }
            }
            $counts['user-policy'] = $n
            foreach ($w in $parsed.Warnings) { [void]$warnings.Add("$userFile $w") }
            [void]$files.Add([ordered]@{ file = $userFile; rules = $n })
        } catch {
            $reason = "invalid ${userFile}: $($_.Exception.Message)"
        }
    } elseif ($state.Status -eq 'error') {
        $reason = "$userFile could not be read: $($state.Error)"
    }
    if ($reason) {
        # Fail closed: without the user's rules nothing is safe to show.
        [void]$blocked.Add([ordered]@{ share = '(all shares)'; reason = $reason })
        [void]$rules.Add(@{
                Pattern = $userFile; Source = 'user-policy-error'
                Regex   = New-Object regex('^\\\\', ([Text.RegularExpressions.RegexOptions]'IgnoreCase, CultureInvariant'))
            })
    }

    $seen = @{}
    foreach ($srv in $Targets) {
        foreach ($sh in $srv.Shares) {
            $root = "\\$($srv.Name)\$($sh.Name)"
            $canon = Get-WssCanonicalUnc $root
            if ($seen.ContainsKey($canon)) { continue }
            $seen[$canon] = $true
            $state = Read-WssSharePolicy $root $Config.PolicyTtl
            if ($state.Status -eq 'none') { continue }
            $reason = $null
            if ($state.Status -eq 'ok') {
                try {
                    $parsed = ConvertFrom-WssPolicyText $state.Content
                    $shareRules = @()
                    foreach ($p in $parsed.Patterns) { $shareRules += New-WssPolicyRule -Pattern $p -Source "share-policy $root" -ShareRoot $canon }
                    foreach ($r in $shareRules) { [void]$rules.Add($r) }
                    $counts['share-policy'] += $shareRules.Count
                    foreach ($w in $parsed.Warnings) { [void]$warnings.Add("$root\$($script:PolicyFileName) $w") }
                    [void]$files.Add([ordered]@{ share = $root; rules = $shareRules.Count })
                } catch {
                    $reason = "invalid $($script:PolicyFileName): $($_.Exception.Message)"
                }
            } else {
                $reason = "$($script:PolicyFileName) could not be read: $($state.Error)"
            }
            if ($reason) {
                [void]$blocked.Add([ordered]@{ share = $root; reason = $reason })
                [void]$rules.Add(@{
                        Pattern = $root; Source = 'share-policy-error'
                        Regex   = New-Object regex(('^' + [regex]::Escape($canon) + '(?:\\.*)?$'), ([Text.RegularExpressions.RegexOptions]'IgnoreCase, CultureInvariant'))
                    })
            }
        }
    }
    return @{ Rules = $rules; Warnings = $warnings; BlockedShares = $blocked; PolicyFiles = $files; Counts = $counts }
}

function Test-WssBlocked {
    <# Returns the first matching deny rule for a UNC path, or $null. #>
    param([string]$Path, $Policy, [switch]$ExpandShortNames)
    $c = Get-WssCanonicalUnc $Path -ExpandShortNames:$ExpandShortNames
    if (-not $c) { return $null }
    foreach ($r in $Policy.Rules) { if ($r.Regex.IsMatch($c)) { return $r } }
    return $null
}

function Get-WssFinalPath {
    <# Path after following client-side symbolic links (GetFinalPathNameByHandle); $null if unavailable. #>
    param([string]$Path)
    if (-not (Test-WssIsWindows)) { return $null }
    try {
        if (-not $script:FinalPathTypeLoaded) {
            Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class WssNativePath {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern uint GetFinalPathNameByHandleW(SafeFileHandle handle, StringBuilder buffer, uint length, uint flags);
    public static string FinalPath(string path) {
        using (SafeFileHandle h = CreateFileW(path, 0, 7, IntPtr.Zero, 3, 0x02000000, IntPtr.Zero)) {
            if (h.IsInvalid) return null;
            StringBuilder sb = new StringBuilder(32768);
            uint n = GetFinalPathNameByHandleW(h, sb, 32768, 0);
            if (n == 0 || n >= 32768) return null;
            return sb.ToString();
        }
    }
}
'@
            $script:FinalPathTypeLoaded = $true
        }
        $f = [WssNativePath]::FinalPath($Path)
        if (-not $f) { return $null }
        if ($f.StartsWith('\\?\UNC\')) { return '\\' + $f.Substring(8) }
        if ($f.StartsWith('\\?\')) { return $f.Substring(4) }
        return $f
    } catch {
        return $null
    }
}

function Assert-WssAllowed {
    <# Throws if the path (or the real path behind client-side symlinks) is blocked by policy. #>
    param([string]$Path, $Policy, [switch]$CheckFinalPath)
    $rule = Test-WssBlocked $Path $Policy -ExpandShortNames
    if (-not $rule -and $CheckFinalPath) {
        $final = Get-WssFinalPath $Path
        if ($final) {
            if (-not $final.StartsWith('\\')) { throw "Access to '$Path' is blocked: it resolves to a local path ($final)." }
            $rule = Test-WssBlocked $final $Policy -ExpandShortNames
        }
    }
    if ($rule) { throw "Access to '$Path' is blocked by the access policy ($($rule.Source): $($rule.Pattern))." }
}

function Get-WssPolicySummary {
    param($Policy)
    $out = [ordered]@{
        rule_counts    = $Policy.Counts
        policy_files   = @($Policy.PolicyFiles)
        blocked_shares = @($Policy.BlockedShares)
    }
    if ($Policy.Warnings.Count -gt 0) { $out.warnings = @($Policy.Warnings) }
    return $out
}

# ---------------------------------------------------------------------------
# Copying files to the local PC (e.g. into the Claude Cowork workspace folder)
# ---------------------------------------------------------------------------

$script:WorkspaceCache = @{}

function Get-WssUniquePath {
    <# Returns Directory\Name, or "Name (n).ext" if that file already exists. #>
    param([string]$Directory, [string]$Name)
    $candidate = [IO.Path]::Combine($Directory, $Name)
    if (-not (Test-Path -LiteralPath $candidate)) { return $candidate }
    $base = [IO.Path]::GetFileNameWithoutExtension($Name)
    $ext = [IO.Path]::GetExtension($Name)
    for ($i = 1; $i -lt 10000; $i++) {
        $candidate = [IO.Path]::Combine($Directory, "$base ($i)$ext")
        if (-not (Test-Path -LiteralPath $candidate)) { return $candidate }
    }
    throw "Could not find a free file name for '$Name' in '$Directory'."
}

function Resolve-WssLocalDestination {
    <#
      Validates a local destination folder: must be an absolute path on a local disk,
      never a UNC path or a mapped network drive (copy_file must not write to servers).
    #>
    param([string]$Path, $Targets)
    if (-not $Path -or -not $Path.Trim()) { throw 'destination is empty' }
    $p = [Environment]::ExpandEnvironmentVariables($Path.Trim())
    if ($p -eq '~' -or $p.StartsWith('~/') -or $p.StartsWith('~\')) {
        $p = [Environment]::GetFolderPath('UserProfile') + $p.Substring(1)
    }
    if (Test-WssIsWindows) {
        $p = $p -replace '/', '\'
        if ($p.StartsWith('\\')) { throw "Destination '$Path' is a network path. copy_file only writes to local folders on this PC." }
        if ($p -notmatch '^[A-Za-z]:\\') { throw "Destination '$Path' must be an absolute local Windows path such as C:\Users\me\Documents\Claude." }
        $drive = $p.Substring(0, 2).ToUpperInvariant()
        foreach ($srv in $Targets) {
            foreach ($sh in $srv.Shares) {
                if ($sh.Drives -contains $drive) { throw "Destination '$Path' is on mapped network drive $drive. copy_file only writes to local folders on this PC." }
            }
        }
        try {
            if ((New-Object IO.DriveInfo($drive)).DriveType -eq [IO.DriveType]::Network) {
                throw "Destination '$Path' is on network drive $drive. copy_file only writes to local folders on this PC."
            }
        } catch [System.ArgumentException] { }
    } elseif (-not [IO.Path]::IsPathRooted($p)) {
        throw "Destination '$Path' must be an absolute path."
    }
    return [IO.Path]::GetFullPath($p)
}

function Test-WssPathUnder {
    <# True if Path equals Root or lies below it (case-insensitive, both already full paths). #>
    param([string]$Path, [string]$Root)
    if (-not $Path -or -not $Root) { return $false }
    $p = $Path.TrimEnd('\', '/')
    $r = $Root.TrimEnd('\', '/')
    if (-not $r) { return $false }
    return ($p -ieq $r -or $p.StartsWith($r + '\', [StringComparison]::OrdinalIgnoreCase) -or $p.StartsWith($r + '/', [StringComparison]::OrdinalIgnoreCase))
}

function Get-WssRealPath {
    <#
      Full path with 8.3 short names, symbolic links and junctions resolved (Windows), so prefix checks
      cannot be bypassed with C:\Users\RUNNER~1 or a junction. Resolves the deepest existing ancestor and
      appends the rest. Returns the plain full path elsewhere or when resolution fails.
    #>
    param([string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    if (-not (Test-WssIsWindows)) { return $full }
    $existing = $full
    $tail = @()
    while ($existing -and -not (Test-Path -LiteralPath $existing)) {
        $tail = @([IO.Path]::GetFileName($existing)) + $tail
        $existing = [IO.Path]::GetDirectoryName($existing)
    }
    if (-not $existing) { return $full }
    $real = Get-WssFinalPath $existing
    if (-not $real) { return $full }
    foreach ($t in $tail) { $real = [IO.Path]::Combine($real, $t) }
    return $real
}

function Test-WssBroadFolder {
    <# True for folders too broad to serve as a workspace: the search roots, the user profile and its top-level known folders. #>
    param([string]$Dir, [string[]]$Roots = @())
    $profileDir = [Environment]::GetFolderPath('UserProfile')
    $broad = @($profileDir) + @($Roots)
    foreach ($r in @($profileDir) + @($Roots)) {
        foreach ($n in @('Documents', 'Desktop', 'Downloads', 'Pictures', 'Music', 'Videos', 'OneDrive')) { if ($r) { $broad += [IO.Path]::Combine($r, $n) } }
    }
    foreach ($f in @('MyDocuments', 'Desktop', 'MyPictures', 'MyMusic', 'MyVideos')) { $broad += [Environment]::GetFolderPath($f) }
    foreach ($b in $broad) {
        if ($b -and $Dir.TrimEnd('\', '/') -ieq ([IO.Path]::GetFullPath($b)).TrimEnd('\', '/')) { return $true }
    }
    return $false
}

function Assert-WssSafeLocalDestination {
    <#
      Refuses local folders where a copied file could run code or change configuration: Windows and program
      folders, AppData (Startup, Claude's own configuration, WindowsApps on PATH, ...), dot folders in the
      user profile (.ssh, .claude, ...), PowerShell profile folders, the profile root and drive roots.
      The temp folder is allowed. Checked on the real path (short names and links resolved).
    #>
    param([string]$Dir)
    $real = Get-WssRealPath $Dir
    $tempDir = Get-WssRealPath ([IO.Path]::GetTempPath())
    if (Test-WssPathUnder $real $tempDir) { return }
    $msg = "Destination '$Dir' is a system, program or configuration folder; copy_file only writes to ordinary folders such as the Cowork workspace or Downloads."
    if ($real -match '^[A-Za-z]:\\?$' -or $real -eq '/') { throw $msg }
    $profileDir = [Environment]::GetFolderPath('UserProfile')
    $docs = [Environment]::GetFolderPath('MyDocuments')
    $denied = @(
        $env:APPDATA, $env:LOCALAPPDATA, $env:ProgramData, $env:SystemRoot, $env:windir,
        $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramW6432,
        [Environment]::GetFolderPath('Startup'), [Environment]::GetFolderPath('CommonStartup')
    )
    if ($profileDir) { $denied += [IO.Path]::Combine($profileDir, 'AppData') }
    if ($docs) { $denied += [IO.Path]::Combine($docs, 'WindowsPowerShell'); $denied += [IO.Path]::Combine($docs, 'PowerShell') }
    foreach ($d in $denied) {
        if (-not $d) { continue }
        if ((Test-WssPathUnder $real $d) -or (Test-WssPathUnder $real (Get-WssRealPath $d))) { throw $msg }
    }
    if ($profileDir) {
        $realProfile = Get-WssRealPath $profileDir
        if ($real.TrimEnd('\', '/') -ieq $realProfile.TrimEnd('\', '/')) { throw $msg }
        if (Test-WssPathUnder $real $realProfile) {
            foreach ($seg in ($real.Substring($realProfile.TrimEnd('\', '/').Length) -split '[\\/]')) {
                if ($seg.StartsWith('.')) { throw $msg }
            }
        }
    }
}

function Find-WssMarkerDirectory {
    <#
      Locates the folder containing a marker file (created by Claude inside its Cowork
      workspace folder) by searching the user's profile and OneDrive folders.
    #>
    param([string]$Marker, [string[]]$Roots = $null, [int]$MaxDepth = 6, [int]$TimeoutSeconds = 20)
    # A fixed prefix, so that ordinary files (.gitconfig, desktop.ini, ...) cannot pose as a marker
    # and turn the user profile or Documents into a "workspace" that save_file may upload from.
    if ($Marker -notmatch '^\.wss-[A-Za-z0-9_-]{8,120}$') {
        throw "Invalid marker '$Marker' (must start with '.wss-' followed by 8-120 letters, digits, '_' or '-', e.g. .wss-target-7f3k9q2m)."
    }
    if ($script:WorkspaceCache.ContainsKey($Marker)) { return $script:WorkspaceCache[$Marker] }
    if (-not $Roots) {
        $Roots = @()
        foreach ($r in @($env:OneDrive, $env:OneDriveCommercial, $env:OneDriveConsumer, [Environment]::GetFolderPath('UserProfile'))) {
            if ($r -and (Test-Path -LiteralPath $r) -and -not ($Roots -contains $r)) { $Roots += $r }
        }
    }
    $skip = @('AppData', 'node_modules', '$Recycle.Bin', 'Application Data', 'Local Settings')
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $queue = New-Object System.Collections.Queue
    foreach ($r in $Roots) { $queue.Enqueue(@($r, 0)) }
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    while ($queue.Count -gt 0) {
        if ((Get-Date) -gt $deadline) { break }
        $item = $queue.Dequeue()
        $dir = $item[0]; $depth = $item[1]
        if (-not $seen.Add($dir)) { continue }
        $markerFile = [IO.Path]::Combine($dir, $Marker)
        if (Test-Path -LiteralPath $markerFile -PathType Leaf) {
            if ((Get-Item -LiteralPath $markerFile -Force).Length -gt 1KB) { throw "'$markerFile' is not an empty marker file." }
            if (Test-WssBroadFolder $dir $Roots) {
                throw "The marker '$Marker' is in '$dir', which is too broad to use as a workspace (user profile, OneDrive or a top-level folder such as Documents). Use a dedicated sub-folder, or pass destination as a Windows path."
            }
            $script:WorkspaceCache[$Marker] = $dir
            return $dir
        }
        if ($depth -ge $MaxDepth) { continue }
        try {
            foreach ($sub in [IO.Directory]::GetDirectories($dir)) {
                $name = [IO.Path]::GetFileName($sub)
                if ($name.StartsWith('.') -or ($skip -contains $name)) { continue }
                try {
                    if (([IO.File]::GetAttributes($sub) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                } catch { continue }
                $queue.Enqueue(@($sub, ($depth + 1)))
            }
        } catch { }
    }
    throw "Could not find a folder containing the marker file '$Marker' in the user profile ($($Roots -join ', ')). Create the marker in the Cowork workspace folder first, or pass destination as a Windows path."
}

function Copy-WssOneFile {
    <# Copies one (already validated) source file into DestinationDir. #>
    param([string]$Source, [string]$DestinationDir, [bool]$Overwrite = $false, [int64]$MaxBytes = 500MB)
    if (Test-Path -LiteralPath $Source -PathType Container) { throw 'is a folder; use list_directory and copy the files you need.' }
    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) { throw 'file not found.' }
    $item = Get-Item -LiteralPath $Source -Force
    if ($item.Length -gt $MaxBytes) { throw "file is larger than the copy limit ($([Math]::Round($MaxBytes / 1MB)) MB)." }
    $name = $item.Name
    if ($Overwrite) { $target = [IO.Path]::Combine($DestinationDir, $name) } else { $target = Get-WssUniquePath $DestinationDir $name }
    [IO.File]::Copy($item.FullName, $target, $Overwrite)
    try { [IO.File]::SetLastWriteTimeUtc($target, $item.LastWriteTimeUtc) } catch { }
    $result = [ordered]@{ local_path = $target; size = [int64]$item.Length; modified = ConvertTo-WssIso $item.LastWriteTime }
    if ([IO.Path]::GetFileName($target) -ne $name) { $result.renamed_to = [IO.Path]::GetFileName($target) }
    return $result
}

function Copy-WssFiles {
    param([hashtable]$Arguments, [hashtable]$Config = (Get-WssConfig), $Targets = $null)
    if ($null -eq $Targets) { $Targets = @(Get-WssTargets -Config $Config) }

    $sources = @()
    if ($Arguments.path) { $sources += "$($Arguments.path)" }
    if ($Arguments.paths) { foreach ($x in @($Arguments.paths)) { if ($x -and -not ($sources -contains "$x")) { $sources += "$x" } } }
    if ($sources.Count -eq 0) { throw 'Provide path (one file) or paths (several files) to copy.' }
    if ($sources.Count -gt 50) { throw 'At most 50 files can be copied per call.' }

    $destSource = 'argument'
    if ($Arguments.destination_marker) {
        $dest = Find-WssMarkerDirectory -Marker "$($Arguments.destination_marker)"
        $destSource = 'marker'
    } elseif ($Arguments.destination) {
        $dest = "$($Arguments.destination)"
    } elseif ($Config.DownloadDir) {
        $dest = "$($Config.DownloadDir)"; $destSource = 'config'
    } else {
        $dest = [IO.Path]::Combine([Environment]::GetFolderPath('UserProfile'), 'Downloads', 'Windows Server Search')
        $destSource = 'default'
    }
    $dest = Resolve-WssLocalDestination $dest $Targets
    if ($Arguments.subfolder) {
        $sub = "$($Arguments.subfolder)"
        if ($sub -match '(^|[\\/])\.\.([\\/]|$)' -or [IO.Path]::IsPathRooted($sub) -or $sub -match '[:*?"<>|]') { throw "Invalid subfolder '$sub'." }
        $dest = [IO.Path]::GetFullPath([IO.Path]::Combine($dest, $sub))
    }
    if ($Config.ConfigFile) {
        $cfgDir = [IO.Path]::GetFullPath([IO.Path]::GetDirectoryName($Config.ConfigFile)).TrimEnd('\', '/')
        $sep = [IO.Path]::DirectorySeparatorChar
        if ($dest.TrimEnd('\', '/') -ieq $cfgDir -or $dest.StartsWith($cfgDir + $sep, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Destination '$dest' is the configuration folder of this plugin; choose another folder."
        }
    }
    Assert-WssSafeLocalDestination $dest
    if (-not (Test-Path -LiteralPath $dest -PathType Container)) { [void](New-Item -ItemType Directory -Path $dest -Force) }
    # Programs and scripts only go to the workspace (marker) or the download folder, never to an arbitrary folder.
    $execRules = @()
    if ($destSource -eq 'argument') { $execRules = @(Get-WssWriteRules) }

    $overwrite = ConvertTo-WssBool $Arguments.overwrite $false
    $policy = Get-WssPolicy -Config $Config -Targets $Targets
    $maxBytes = [int64]$Config.MaxCopyMB * 1MB
    $copied = New-Object System.Collections.ArrayList
    $errors = New-Object System.Collections.ArrayList
    foreach ($src in $sources) {
        try {
            $unc = Resolve-WssPath $src $Targets
            Assert-WssAllowed $unc $policy -CheckFinalPath
            $c = Get-WssCanonicalUnc $unc
            foreach ($rule in $execRules) {
                if ($rule.Regex.IsMatch($c)) { throw "programs and scripts can only be copied into the workspace (destination_marker) or the download folder, not to '$dest'." }
            }
            $r = Copy-WssOneFile -Source $unc -DestinationDir $dest -Overwrite $overwrite -MaxBytes $maxBytes
            $entry = [ordered]@{ source = $unc }
            $drivePath = Convert-WssUncToDrivePath $unc $Targets
            if ($drivePath) { $entry.source_drive_path = $drivePath }
            foreach ($k in $r.Keys) { $entry[$k] = $r[$k] }
            [void]$copied.Add($entry)
        } catch {
            [void]$errors.Add([ordered]@{ source = $src; error = $_.Exception.Message })
        }
    }
    if ($copied.Count -eq 0) {
        throw ('No file was copied: ' + (($errors | ForEach-Object { "$($_.source): $($_.error)" }) -join ' | '))
    }
    $out = [ordered]@{ destination = $dest; destination_source = $destSource; copied = @($copied) }
    if ($errors.Count -gt 0) { $out.errors = @($errors) }
    if ($destSource -eq 'default') {
        $out.note = 'Copied to the default download folder. In Claude Cowork this folder is not visible in your workspace: pass destination_marker (or destination) so files land in the folder connected to the session.'
    }
    return $out
}

# ---------------------------------------------------------------------------
# Writing files back to the server (save_file) - enabled by default, can be disabled
# ---------------------------------------------------------------------------

# Never writable, in addition to the access policy: policy files and executable / script types.
$script:WriteDenyPatterns = @(
    '**\.claude-policy',
    '**\*.exe', '**\*.dll', '**\*.com', '**\*.scr', '**\*.msi', '**\*.msp', '**\*.cpl', '**\*.sys', '**\*.drv',
    '**\*.bat', '**\*.cmd', '**\*.ps1', '**\*.psm1', '**\*.psd1', '**\*.vbs', '**\*.vbe', '**\*.js', '**\*.jse',
    '**\*.wsf', '**\*.wsh', '**\*.hta', '**\*.lnk', '**\*.url', '**\*.reg', '**\*.jar', '**\*.appx', '**\*.msix',
    '**\desktop.ini', '**\autorun.inf'
)
$script:RegistryWriteVetoProvider = $null   # scriptblock -> $true when IT disabled writing (tests)

function Test-WssWriteVetoed {
    <# Group Policy / Intune: DisableWrite=1 under HKLM or HKCU \SOFTWARE\Policies\WindowsServerSearchMcp. #>
    if ($script:RegistryWriteVetoProvider) { return [bool](& $script:RegistryWriteVetoProvider) }
    if (-not (Test-WssIsWindows)) { return $false }
    foreach ($key in @('HKLM:\SOFTWARE\Policies\WindowsServerSearchMcp', 'HKCU:\SOFTWARE\Policies\WindowsServerSearchMcp')) {
        try {
            $v = (Get-ItemProperty -LiteralPath $key -Name DisableWrite -ErrorAction Stop).DisableWrite
            if ("$v" -ne '' -and "$v" -ne '0') { return $true }
        } catch { }
    }
    return $false
}

function Get-WssWriteStatus {
    param([hashtable]$Config)
    $veto = Test-WssWriteVetoed
    return [ordered]@{
        enabled                  = ([bool]$Config.WriteEnabled -and -not $veto)
        configured               = [bool]$Config.WriteEnabled
        disabled_by_group_policy = $veto
        allow_overwrite          = [bool]$Config.WriteAllowOverwrite
        max_file_mb              = $Config.WriteMaxMB
    }
}

function Test-WssFileName {
    <# Validates a single Windows file name (no folders). #>
    param([string]$Name)
    if (-not $Name -or -not $Name.Trim()) { throw 'File name is empty.' }
    if ($Name.Length -gt 255) { throw "File name '$Name' is too long." }
    if ($Name -match '[<>:"/\\|?*\x00-\x1f]') { throw "File name '$Name' contains characters that are not allowed (< > : `" / \ | ? *)." }
    if ($Name -ne $Name.TrimEnd('.', ' ') -or $Name -ne $Name.TrimStart(' ')) { throw "File name '$Name' must not start with a space or end with a dot or space." }
    if ($Name -match '^(?i)(CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])(\..*)?$') { throw "File name '$Name' is reserved by Windows." }
}

function Get-WssWriteRules {
    $rules = @()
    foreach ($p in $script:WriteDenyPatterns) { $rules += New-WssPolicyRule -Pattern $p -Source 'built-in write protection' }
    return $rules
}

function Assert-WssWritable {
    <# Throws if a target path may not be written: access policy or built-in write protection. #>
    param([string]$TargetUnc, $Policy, $WriteRules)
    $rule = Test-WssBlocked $TargetUnc $Policy -ExpandShortNames
    if ($rule) { throw "Writing '$TargetUnc' is blocked by the access policy ($($rule.Source): $($rule.Pattern))." }
    $c = Get-WssCanonicalUnc $TargetUnc -ExpandShortNames
    foreach ($r in $WriteRules) {
        if ($r.Regex.IsMatch($c)) { throw "Writing '$TargetUnc' is not allowed ($($r.Source): $($r.Pattern))." }
    }
}

function Get-WssAllowedSourceRoots {
    <# Local folders that save_file may read from: Cowork workspaces found via marker, download folders. #>
    param([hashtable]$Config)
    $roots = @()
    foreach ($v in $script:WorkspaceCache.Values) { $roots += $v }
    if ($Config.DownloadDir) { try { $roots += [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables("$($Config.DownloadDir)")) } catch { } }
    $roots += [IO.Path]::Combine([Environment]::GetFolderPath('UserProfile'), 'Downloads', 'Windows Server Search')
    return $roots
}

function Resolve-WssSaveSource {
    <# Resolves a local source file and checks it lies inside an allowed source root. #>
    param([string]$Path, [string[]]$Roots)
    $full = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Path))
    if ($full.StartsWith('\\')) { throw "Source '$Path' must be a local file (use the Cowork workspace or the download folder)." }
    $real = Get-WssRealPath $full
    $root = $null
    foreach ($r in $Roots) {
        $rr = $r.TrimEnd('\', '/')
        # The real path (links resolved) must stay inside the same root as well.
        if ($full.StartsWith($rr + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -and
            (Test-WssPathUnder $real (Get-WssRealPath $rr))) { $root = $rr; break }
    }
    if (-not $root) {
        throw "Source '$Path' is outside the folders save_file may read from (the Cowork workspace located via source_marker, or the download folder)."
    }
    # No hidden or dot files/folders (.ssh, .git, .env, the marker itself, ...).
    foreach ($seg in ($full.Substring($root.Length) -split '[\\/]')) {
        if ($seg.StartsWith('.')) { throw "Source '$Path' is a hidden file or inside a hidden folder ('$seg') and cannot be uploaded." }
    }
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "Source file not found: $full" }
    $attr = [IO.File]::GetAttributes($full)
    if (($attr -band ([IO.FileAttributes]::Hidden -bor [IO.FileAttributes]::System)) -ne 0) {
        throw "Source '$Path' is a hidden or system file and cannot be uploaded."
    }
    return $full
}

function Test-WssOwnPermissions {
    <# True if a file has explicit or protected (non-inherited) permissions; also when they can't be read (fail closed). #>
    param([string]$Path)
    if (-not (Test-WssIsWindows)) { return $false }
    try {
        # .NET directly, not Get-Acl: its module fails to load in powershell.exe 5.1 started from pwsh 7 (PSModulePath).
        $acl = New-Object System.Security.AccessControl.FileSecurity($Path, [System.Security.AccessControl.AccessControlSections]::Access)
        if ($acl.AreAccessRulesProtected) { return $true }
        return (@($acl.GetAccessRules($true, $false, [Security.Principal.SecurityIdentifier])).Count -gt 0)
    } catch {
        Write-WssLog "Could not read the permissions of '$Path': $($_.Exception.Message)"
        return $true
    }
}

function Save-WssOneFile {
    <#
      Writes one file into TargetDir: via a hidden temp file + rename (no partial files).
      Existing file: numbered copy unless Overwrite, in which case the old version is kept as
      "<name>.claude-backup-<timestamp>" next to it (both keep the original file's permissions).
    #>
    param(
        [string]$TargetDir, [string]$Name,
        [string]$SourceFile, [string]$Content, [string]$Encoding = 'utf8',
        [bool]$Overwrite = $false, [int64]$MaxBytes = 100MB
    )
    Test-WssFileName $Name
    if ($SourceFile) {
        $len = (Get-Item -LiteralPath $SourceFile -Force).Length
        if ($len -gt $MaxBytes) { throw "file is larger than the write limit ($([Math]::Round($MaxBytes / 1MB)) MB)." }
    } else {
        switch ($Encoding) {
            'utf8' { $enc = New-Object Text.UTF8Encoding($false) }
            'utf8-bom' { $enc = New-Object Text.UTF8Encoding($true) }
            'utf16' { $enc = [Text.Encoding]::Unicode }
            default { throw "Invalid encoding '$Encoding' (use utf8, utf8-bom or utf16)." }
        }
        $bytes = $enc.GetPreamble() + $enc.GetBytes($Content)
        if ($bytes.Length -gt $MaxBytes) { throw "content is larger than the write limit ($([Math]::Round($MaxBytes / 1MB)) MB)." }
    }
    if (-not (Test-Path -LiteralPath $TargetDir -PathType Container)) { [void](New-Item -ItemType Directory -Path $TargetDir -Force) }

    $tmp = [IO.Path]::Combine($TargetDir, '.~claude-upload-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        if ($SourceFile) { [IO.File]::Copy($SourceFile, $tmp, $false) } else { [IO.File]::WriteAllBytes($tmp, [byte[]]$bytes) }
        try { [IO.File]::SetAttributes($tmp, [IO.FileAttributes]::Hidden) } catch { }

        $target = [IO.Path]::Combine($TargetDir, $Name)
        $backup = $null
        if (Test-Path -LiteralPath $target) {
            if (Test-Path -LiteralPath $target -PathType Container) { throw "a folder named '$Name' already exists." }
            if ($Overwrite) {
                $backup = Get-WssUniquePath $TargetDir ($Name + '.claude-backup-' + (Get-Date).ToString('yyyyMMdd-HHmmss'))
                # ReplaceFile: the new content takes over the replaced file's ACL, attributes and streams, and the
                # previous version is renamed to the backup, so it keeps its own ACL. Copy + delete + move would give
                # both files the folder's inherited permissions instead. Fails rather than drop the ACL.
                $replaceError = $null
                try { [IO.File]::Replace($tmp, $target, $backup, $false) } catch {
                    # restore the previous version if it was already renamed to the backup
                    if (-not (Test-Path -LiteralPath $target) -and (Test-Path -LiteralPath $backup)) { try { [IO.File]::Move($backup, $target) } catch { } }
                    if (-not (Test-Path -LiteralPath $target) -or -not (Test-Path -LiteralPath $tmp)) { throw }
                    $replaceError = $_.Exception.Message
                }
                if ($replaceError) {
                    # ReplaceFile also needs the right to change permissions, which shares granting only "Change" lack.
                    # Without own permissions on the file, rename + move is equivalent: the backup keeps the file's
                    # inherited permissions and the new version inherits the same ones.
                    if (Test-WssOwnPermissions $target) {
                        throw "'$Name' has its own permissions, which can't be carried over to the new version here ($replaceError). Save it under a new name instead (overwrite=false)."
                    }
                    [IO.File]::Move($target, $backup)
                    try { [IO.File]::Move($tmp, $target) } catch {
                        try { [IO.File]::Move($backup, $target) } catch { }
                        throw
                    }
                }
            } else {
                $target = Get-WssUniquePath $TargetDir $Name
                [IO.File]::Move($tmp, $target)
            }
        } else {
            [IO.File]::Move($tmp, $target)
        }
        try { [IO.File]::SetAttributes($target, ([IO.File]::GetAttributes($target) -band (-bnot [IO.FileAttributes]::Hidden))) } catch { }
        if ($SourceFile) { try { [IO.File]::SetLastWriteTimeUtc($target, (Get-Item -LiteralPath $SourceFile).LastWriteTimeUtc) } catch { } }
        $out = [ordered]@{ target = $target; size = [int64](Get-Item -LiteralPath $target -Force).Length; overwritten = [bool]$backup }
        if ($backup) { $out.backup = $backup }
        if ([IO.Path]::GetFileName($target) -ne $Name) { $out.renamed_to = [IO.Path]::GetFileName($target) }
        return $out
    } finally {
        if (Test-Path -LiteralPath $tmp) { try { [IO.File]::Delete($tmp) } catch { } }
    }
}

function Write-WssWriteLog {
    param([hashtable]$Config, $Entry)
    $path = $Config.WriteLogPath
    if (-not $path) {
        $base = $env:LOCALAPPDATA
        if (-not $base) { $base = [IO.Path]::GetTempPath() }
        $path = [IO.Path]::Combine($base, 'windows-server-search-mcp', 'write-log.jsonl')
    }
    $path = [Environment]::ExpandEnvironmentVariables("$path")
    $dir = [IO.Path]::GetDirectoryName($path)
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    $line = ConvertTo-Json -InputObject $Entry -Depth 5 -Compress
    $fs = New-Object IO.FileStream($path, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
    try {
        $b = (New-Object Text.UTF8Encoding($false)).GetBytes($line + "`n")
        $fs.Write($b, 0, $b.Length)
    } finally { $fs.Dispose() }
    return $path
}

function Save-WssFiles {
    param([hashtable]$Arguments, [hashtable]$Config = (Get-WssConfig), $Targets = $null)
    $status = Get-WssWriteStatus $Config
    if ($status.disabled_by_group_policy) { throw 'Writing to servers is disabled by Group Policy (DisableWrite).' }
    if (-not $status.enabled) { throw 'Writing to servers is disabled in the plugin configuration ("write": { "enabled": false }).' }
    if ($null -eq $Targets) { $Targets = @(Get-WssTargets -Config $Config) }

    if (-not $Arguments.destination) { throw 'destination (server folder, e.g. Z:\Reports or \\server\share\Reports) is required.' }
    $destUnc = Resolve-WssPath "$($Arguments.destination)" $Targets
    $policy = Get-WssPolicy -Config $Config -Targets $Targets
    $writeRules = Get-WssWriteRules
    Assert-WssWritable $destUnc $policy $writeRules

    # Collect jobs: inline content, or local files from the workspace / download folder.
    $jobs = @()
    $hasContent = $Arguments.ContainsKey('content') -and $null -ne $Arguments.content
    if ($hasContent) {
        if (-not $Arguments.name) { throw 'name is required when content is given.' }
        if ("$($Arguments.content)".Length -gt 10000000) { throw 'content is too long (max 10 million characters); save it as a file in the workspace and use source_name.' }
        $jobs += @{ Label = 'content'; Name = "$($Arguments.name)"; Content = "$($Arguments.content)" }
    }
    $sourceDir = $null
    if ($Arguments.source_marker) { $sourceDir = Find-WssMarkerDirectory -Marker "$($Arguments.source_marker)" }
    $names = @()
    if ($Arguments.source_name) { $names += "$($Arguments.source_name)" }
    if ($Arguments.source_names) { $names += @($Arguments.source_names | ForEach-Object { "$_" }) }
    if ($names.Count -gt 0 -and -not $sourceDir) { throw 'source_name(s) need source_marker (the marker file in your workspace folder).' }
    foreach ($n in $names) {
        if ($n -match '(^|[\\/])\.\.([\\/]|$)' -or [IO.Path]::IsPathRooted($n)) { throw "Invalid source_name '$n' (must be relative to the workspace folder)." }
        $jobs += @{ Label = $n; Source = [IO.Path]::Combine($sourceDir, $n) }
    }
    if ($Arguments.source_path) { $jobs += @{ Label = "$($Arguments.source_path)"; Source = "$($Arguments.source_path)" } }
    if ($jobs.Count -eq 0) { throw 'Provide content (+ name), source_name(s) with source_marker, or source_path.' }
    if ($jobs.Count -gt 20) { throw 'At most 20 files can be saved per call.' }
    if ($Arguments.name -and $jobs.Count -gt 1) { throw 'name can only be used when saving a single file.' }

    $overwrite = ConvertTo-WssBool $Arguments.overwrite $false
    $notes = @()
    if ($overwrite -and -not $Config.WriteAllowOverwrite) {
        $overwrite = $false
        $notes += 'Overwriting is not allowed by the configuration ("allowOverwrite"); existing files were kept and numbered copies were created instead.'
    }
    $roots = Get-WssAllowedSourceRoots $Config
    $maxBytes = [int64]$Config.WriteMaxMB * 1MB
    $saved = New-Object System.Collections.ArrayList
    $errors = New-Object System.Collections.ArrayList
    $logPath = $null
    foreach ($job in $jobs) {
        try {
            $src = $null
            if ($job.Source) {
                $src = Resolve-WssSaveSource $job.Source $roots
                # Protected types (password vaults, certificates, ...) must not leave the PC under another name either.
                $builtin = @($script:BuiltinDenyPatterns | ForEach-Object { New-WssPolicyRule -Pattern $_ -Source 'built-in' })
                if (Test-WssBlocked ('\\local\source\' + [IO.Path]::GetFileName($src)) @{ Rules = $builtin }) {
                    throw 'this file type is protected and cannot be uploaded.'
                }
            }
            $name = $job.Name
            if (-not $name) { if ($Arguments.name) { $name = "$($Arguments.name)" } else { $name = [IO.Path]::GetFileName($src) } }
            Test-WssFileName $name
            $targetUnc = $destUnc.TrimEnd('\') + '\' + $name
            Assert-WssWritable $targetUnc $policy $writeRules
            $encoding = 'utf8'; if ($Arguments.encoding) { $encoding = "$($Arguments.encoding)".ToLowerInvariant() }
            $r = Save-WssOneFile -TargetDir $destUnc -Name $name -SourceFile $src -Content $job.Content -Encoding $encoding -Overwrite $overwrite -MaxBytes $maxBytes
            # The final name (numbered copy) must be allowed as well.
            Assert-WssWritable $r.target $policy $writeRules
            $entry = [ordered]@{ source = $job.Label }
            foreach ($k in $r.Keys) { $entry[$k] = $r[$k] }
            $drivePath = Convert-WssUncToDrivePath $r.target $Targets
            if ($drivePath) { $entry.drive_path = $drivePath }
            [void]$saved.Add($entry)
            try {
                $logPath = Write-WssWriteLog $Config ([ordered]@{
                        time = (Get-Date).ToUniversalTime().ToString('o'); user = "$env:USERDOMAIN\$env:USERNAME"; computer = $env:COMPUTERNAME
                        source = $job.Label; target = $r.target; size = $r.size; overwritten = $r.overwritten; backup = $r.backup
                    })
            } catch {
                $notes += "Write log could not be updated: $($_.Exception.Message)"
            }
        } catch {
            $msg = $_.Exception.Message
            $ex = $_.Exception
            while ($ex) { if ($ex -is [UnauthorizedAccessException]) { $msg += ' You probably have no write permission for this server folder (share/NTFS permissions); ask the server administrator or choose another folder.'; break }; $ex = $ex.InnerException }
            [void]$errors.Add([ordered]@{ source = $job.Label; error = $msg })
        }
    }
    if ($saved.Count -eq 0) {
        throw ('No file was saved: ' + (($errors | ForEach-Object { "$($_.source): $($_.error)" }) -join ' | '))
    }
    $out = [ordered]@{ destination = $destUnc }
    $dp = Convert-WssUncToDrivePath $destUnc $Targets
    if ($dp) { $out.destination_drive_path = $dp }
    $out.saved = @($saved)
    if ($errors.Count -gt 0) { $out.errors = @($errors) }
    if ($notes.Count -gt 0) { $out.notes = @($notes) }
    if ($logPath) { $out.log = $logPath }
    return $out
}

# ---------------------------------------------------------------------------
# MCP protocol
# ---------------------------------------------------------------------------

function Test-WssStructuredOutput {
    <# Structured tool output (outputSchema / structuredContent) exists since protocol 2025-06-18. #>
    return ($script:ProtocolVersion -and [string]::CompareOrdinal("$script:ProtocolVersion", '2025-06-18') -ge 0)
}

function Get-WssOutputSchemas {
    <# Output schemas of the tools. Kept open (extra fields allowed) and typed only where a value is always
       present, so clients that validate results never reject a real one. #>
    $obj = @{ type = 'object' }
    $arr = @{ type = 'array'; items = $obj }
    $str = @{ type = 'string' }
    $int = @{ type = 'integer' }
    $bool = @{ type = 'boolean' }
    $result = [ordered]@{
        type       = 'object'
        properties = [ordered]@{
            name       = @{ type = @('string', 'null') }
            path       = @{ type = @('string', 'null'); description = 'UNC path' }
            drive_path = @{ type = 'string'; description = 'Path on the mapped drive, when there is one' }
            server     = $str
            size       = $int
            modified   = @{ type = 'string'; description = 'UTC, ISO 8601' }
            snippet    = @{ type = 'string'; description = 'Text around the first match (snippets=true)' }
        }
    }
    return @{
        list_servers   = [ordered]@{ type = 'object'; properties = [ordered]@{ servers = $arr; config = $obj; access_policy = $obj; write = $obj; hint = $str }; required = @('servers') }
        search_files   = [ordered]@{
            type       = 'object'
            properties = [ordered]@{
                servers_queried  = @{ type = 'array'; items = $str }
                result_count     = $int
                hidden_by_policy = $int
                offset           = $int
                next_offset      = @{ type = 'integer'; description = 'Pass as offset to get the next page' }
                policy_note      = $str
                results          = @{ type = 'array'; items = $result }
                errors           = $arr
            }
            required   = @('result_count', 'hidden_by_policy', 'results')
        }
        read_file      = [ordered]@{
            type       = 'object'
            properties = [ordered]@{
                path = $str; drive_path = $str; size_bytes = $int; modified = $str; total_chars = $int
                offset = $int; returned = $int; truncated = $bool; next_offset = $int; content = $str
                find = $str; match_count = $int; passages_truncated = $bool; hint = $str
                passages = @{ type = 'array'; items = [ordered]@{ type = 'object'; properties = [ordered]@{ line = $int; offset = $int; text = $str } } }
            }
            required   = @('path', 'total_chars')
        }
        list_directory = [ordered]@{ type = 'object'; properties = [ordered]@{ path = $str; drive_path = $str; entries = $arr; truncated = $bool; hidden_by_policy = $int }; required = @('path', 'entries') }
        copy_file      = [ordered]@{ type = 'object'; properties = [ordered]@{ destination = $str; destination_source = $str; copied = $arr; errors = $arr; note = $str }; required = @('copied') }
        save_file      = [ordered]@{ type = 'object'; properties = [ordered]@{ destination = $str; destination_drive_path = $str; saved = $arr; errors = $arr; notes = @{ type = 'array'; items = $str }; log = $str }; required = @('saved') }
    }
}

function Get-WssToolDefinitions {
    param([bool]$IncludeWrite = $false, [bool]$AllowOverwrite = $false, [bool]$IncludeOutputSchema = $false)
    $serverProp = @{ type = 'string'; description = 'Restrict to one server (name as returned by list_servers). Default: all servers.' }
    $tools = @(
        [ordered]@{
            name        = 'list_servers'
            title       = 'List Windows servers'
            description = 'Lists the Windows file servers and shares available for searching (auto-discovered from mapped network drives and/or configured), including their drive letters. Set check=true to test whether each server''s search index is reachable.'
            inputSchema = [ordered]@{
                type       = 'object'
                properties = [ordered]@{
                    check = @{ type = 'boolean'; description = 'Run a test query against each server''s Windows Search index.'; default = $false }
                }
            }
            annotations = @{ readOnlyHint = $true; openWorldHint = $false }
        },
        [ordered]@{
            name        = 'search_files'
            title       = 'Search Windows server index'
            description = 'Searches the Windows Search index of the Windows file server(s) for files by content and/or file name, with optional filters. Results include UNC path, mapped drive path, size, dates (UTC), author and relevance rank; snippets=true adds the text around the match for the first results. Files blocked by the access policy are never returned; hidden_by_policy reports how many were withheld. Query syntax: words are ANDed (prefix match), "exact phrase", -exclude, OR between terms. More results: pass next_offset as offset.'
            inputSchema = [ordered]@{
                type       = 'object'
                properties = [ordered]@{
                    query           = @{ type = 'string'; description = 'Search terms, e.g. budget 2024 "project alpha" -draft' }
                    match           = @{ type = 'string'; enum = @('all', 'filename', 'contents'); default = 'all'; description = 'Match terms against file contents+properties+name (all), only file name, or only indexed contents/properties.' }
                    server          = $serverProp
                    path            = @{ type = 'string'; description = 'Restrict to a folder: UNC path (\\server\share\folder) or mapped drive path (Z:\folder).' }
                    extensions      = @{ type = 'array'; items = @{ type = 'string' }; description = 'File extensions to include, e.g. ["pdf","docx"].' }
                    kind            = @{ type = 'string'; description = 'Windows kind filter, e.g. document, picture, music, video, email, folder, program.' }
                    author          = @{ type = 'string'; description = 'Exact document author.' }
                    modified_after  = @{ type = 'string'; description = 'ISO date or date/time, e.g. 2024-01-01 or 2024-01-01T08:00. Without Z or an offset it is the local time of this PC.' }
                    modified_before = @{ type = 'string'; description = 'ISO date or date/time; a plain date (2024-12-31) includes that whole day. Without Z or an offset it is the local time of this PC.' }
                    include_folders = @{ type = 'boolean'; default = $false; description = 'Also return folders.' }
                    sort            = @{ type = 'string'; enum = @('relevance', 'modified', 'name', 'size'); default = 'relevance' }
                    max_results     = @{ type = 'integer'; minimum = 1; maximum = 500; description = 'Maximum results (default from configuration, 50).' }
                    offset          = @{ type = 'integer'; minimum = 0; maximum = 4500; default = 0; description = 'Skip this many results (paging): pass next_offset from the previous search.' }
                    snippets        = @{ type = 'boolean'; default = $false; description = 'Read the first 10 results and add the text around the first match (snippet). Slower; use when you need to judge which results are relevant.' }
                }
            }
            annotations = @{ readOnlyHint = $true; openWorldHint = $false }
        },
        [ordered]@{
            name        = 'read_file'
            title       = 'Read file from Windows server'
            description = 'Reads the text content of a file on a known Windows server share (UNC or mapped drive path): plain-text formats, .docx/.xlsx/.pptx (spreadsheets as tab-separated rows with row numbers, real sheet names and dates), and other formats such as PDF, .doc, .xls, .rtf or .msg when Windows has a filter for them. Long files are returned in chunks; use offset/next_offset to continue. To find something in a long file, pass find: only the matching passages are returned, with their offsets.'
            inputSchema = [ordered]@{
                type       = 'object'
                properties = [ordered]@{
                    path      = @{ type = 'string'; description = 'UNC path (\\server\share\dir\file.txt) or mapped drive path (Z:\dir\file.txt).' }
                    offset    = @{ type = 'integer'; minimum = 0; default = 0; description = 'Character offset to start reading from.' }
                    max_chars = @{ type = 'integer'; minimum = 1; maximum = 200000; default = 20000; description = 'Maximum characters to return.' }
                    find        = @{ type = 'string'; description = 'Return only passages containing this text (case-insensitive; line breaks count as spaces; "a OR b" for alternatives) instead of the content.' }
                    context     = @{ type = 'integer'; minimum = 0; maximum = 20; default = 2; description = 'With find: lines before and after each match.' }
                    max_matches = @{ type = 'integer'; minimum = 1; maximum = 200; default = 20; description = 'With find: maximum passages.' }
                }
                required   = @('path')
            }
            annotations = @{ readOnlyHint = $true; openWorldHint = $false }
        },
        [ordered]@{
            name        = 'list_directory'
            title       = 'List folder on Windows server'
            description = 'Lists files and sub-folders of a folder on a known Windows server share (UNC or mapped drive path).'
            inputSchema = [ordered]@{
                type       = 'object'
                properties = [ordered]@{
                    path        = @{ type = 'string'; description = 'UNC path (\\server\share\dir) or mapped drive path (Z:\dir).' }
                    max_entries = @{ type = 'integer'; minimum = 1; maximum = 2000; default = 200 }
                }
                required   = @('path')
            }
            annotations = @{ readOnlyHint = $true; openWorldHint = $false }
        },
        [ordered]@{
            name        = 'copy_file'
            title       = 'Copy files from Windows server to this PC'
            description = 'Copies files from a known Windows server share to a local folder on this PC so they can be opened or processed with other tools (PDFs, images, large spreadsheets, any format). In Claude Cowork: first create an empty marker file with a unique name (e.g. .wss-target-7f3k9q2m) in your workspace folder, then pass that name as destination_marker; the server finds the matching Windows folder and copies the files next to the marker. Existing files are never overwritten unless overwrite=true (a numbered copy such as "report (1).pdf" is created instead). Never writes to the server, nor to system, program or configuration folders (AppData, dot folders, ...); programs and scripts only go to the workspace or the download folder.'
            inputSchema = [ordered]@{
                type       = 'object'
                properties = [ordered]@{
                    path               = @{ type = 'string'; description = 'File to copy: UNC path (\\server\share\dir\file.pdf) or mapped drive path (Z:\dir\file.pdf).' }
                    paths              = @{ type = 'array'; items = @{ type = 'string' }; maxItems = 50; description = 'Several files to copy (alternative to path).' }
                    destination_marker = @{ type = 'string'; description = 'Name of a marker file you created in the destination folder: .wss- followed by 8-120 random letters, digits, _ or - (e.g. .wss-target-7f3k9q2m). Recommended in Cowork: the files are copied into the folder that contains this marker.' }
                    destination        = @{ type = 'string'; description = 'Absolute local Windows folder, e.g. C:\Users\me\Documents\Claude. Default: the configured download folder, else %USERPROFILE%\Downloads\Windows Server Search.' }
                    subfolder          = @{ type = 'string'; description = 'Optional relative sub-folder inside the destination (created if missing).' }
                    overwrite          = @{ type = 'boolean'; default = $false; description = 'Replace existing files with the same name.' }
                }
            }
            # destructive: overwrite=true replaces local files
            annotations = @{ readOnlyHint = $false; destructiveHint = $true; idempotentHint = $false; openWorldHint = $false }
        }
    ) + $(if ($IncludeWrite) { @(
        [ordered]@{
            name        = 'save_file'
            title       = 'Save file to Windows server'
            description = 'Writes files to a folder on a known Windows server share (UNC or mapped drive path; missing sub-folders are created). Sources: inline text "content" (+ "name"), or files from your Cowork workspace via source_marker (the marker file in your workspace folder, see copy_file) + source_name/source_names. Existing files are kept and a numbered copy is created unless overwrite=true' + $(if ($AllowOverwrite) { ' (the previous version is then kept as <name>.claude-backup-<timestamp>).' } else { '; overwriting is disabled by configuration.' }) + ' Blocked paths, policy files and executable/script types cannot be written. Every write is logged. Only save when the user asked for it.'
            inputSchema = [ordered]@{
                type       = 'object'
                properties = [ordered]@{
                    destination   = @{ type = 'string'; description = 'Target folder on the server: Z:\Reports\2024 or \\server\share\Reports.' }
                    name          = @{ type = 'string'; description = 'File name (required with content; optional rename for a single source file).' }
                    content       = @{ type = 'string'; description = 'Text to write (e.g. Markdown, CSV, JSON, TXT).' }
                    encoding      = @{ type = 'string'; enum = @('utf8', 'utf8-bom', 'utf16'); default = 'utf8'; description = 'Encoding for content (utf8-bom helps Excel open CSV files).' }
                    source_marker = @{ type = 'string'; description = 'Marker file name in your Cowork workspace folder (identifies the folder that source_name(s) are relative to).' }
                    source_name   = @{ type = 'string'; description = 'File in the workspace folder to upload, relative to the marker''s folder (e.g. report.docx or out/chart.png).' }
                    source_names  = @{ type = 'array'; items = @{ type = 'string' }; maxItems = 20; description = 'Several workspace files to upload.' }
                    source_path   = @{ type = 'string'; description = 'Absolute local Windows path of a file inside the workspace or download folder.' }
                    overwrite     = @{ type = 'boolean'; default = $false; description = 'Replace an existing file with the same name (keeps a backup of the old version).' }
                }
                required   = @('destination')
            }
            annotations = @{ readOnlyHint = $false; destructiveHint = $AllowOverwrite; idempotentHint = $false; openWorldHint = $false }
        }) } else { @() })
    if ($IncludeOutputSchema) {
        $schemas = Get-WssOutputSchemas
        foreach ($t in $tools) { if ($schemas.ContainsKey($t.name)) { $t.outputSchema = $schemas[$t.name] } }
    }
    return $tools
}

function ConvertTo-WssHashtable {
    <# Converts PSCustomObject (from ConvertFrom-Json) into nested hashtables/arrays. #>
    param($InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $h = @{}
        foreach ($p in $InputObject.PSObject.Properties) { $h[$p.Name] = ConvertTo-WssHashtable $p.Value }
        return $h
    }
    if ($InputObject -is [array]) {
        $a = @()
        foreach ($i in $InputObject) { $a += , (ConvertTo-WssHashtable $i) }
        return , $a
    }
    return $InputObject
}

function ConvertTo-WssJson {
    param($Object)
    return (ConvertTo-Json -InputObject $Object -Depth 30 -Compress)
}

function Invoke-WssTool {
    param([string]$Name, [hashtable]$Arguments)
    if ($null -eq $Arguments) { $Arguments = @{} }
    switch ($Name) {
        'list_servers' { return Get-WssServerList -Arguments $Arguments }
        'search_files' { return Search-Wss -Arguments $Arguments }
        'read_file' { return Read-WssFile -Arguments $Arguments }
        'list_directory' { return Get-WssDirectoryListing -Arguments $Arguments }
        'copy_file' { return Copy-WssFiles -Arguments $Arguments }
        'save_file' { return Save-WssFiles -Arguments $Arguments }
        default { throw [System.Collections.Generic.KeyNotFoundException]::new("Unknown tool: $Name") }
    }
}

function New-WssResponse {
    param($Id, $Result)
    return [ordered]@{ jsonrpc = '2.0'; id = $Id; result = $Result }
}

function New-WssError {
    param($Id, [int]$Code, [string]$Message)
    return [ordered]@{ jsonrpc = '2.0'; id = $Id; error = [ordered]@{ code = $Code; message = $Message } }
}

function Invoke-WssRequest {
    <# Handles one JSON-RPC message (hashtable). Returns a response object or $null for notifications. #>
    param([hashtable]$Message)
    $hasId = $Message.ContainsKey('id')
    $id = $null; if ($hasId) { $id = $Message.id }
    $method = $Message.method
    $params = $Message.params
    if ($null -eq $params) { $params = @{} }

    if (-not $method) {
        if ($hasId) { return New-WssError $id -32600 'Invalid Request' }
        return $null
    }
    if (-not $hasId) { return $null }  # notifications (initialized, cancelled, ...)

    switch ($method) {
        'initialize' {
            $requested = "$($params.protocolVersion)"
            $version = $script:SupportedProtocolVersions[0]
            if ($script:SupportedProtocolVersions -contains $requested) { $version = $requested }
            $script:ProtocolVersion = $version
            return New-WssResponse $id ([ordered]@{
                    protocolVersion = $version
                    capabilities    = [ordered]@{ tools = [ordered]@{ listChanged = $false } }
                    serverInfo      = [ordered]@{ name = $script:ServerName; title = 'Windows Server Search'; version = $script:ServerVersion }
                    instructions    = 'Search files on Windows file servers through their Windows Search index. Call list_servers first to see available servers/shares, then search_files; use read_file to read results as text (read_file with find returns only the matching passages of a long file), or copy_file to copy files into your workspace (e.g. images, or files read_file cannot convert). Some paths may be blocked by an access policy: report hidden_by_policy counts to the user and never try to work around a block.'
                })
        }
        'ping' { return New-WssResponse $id @{} }
        'tools/list' {
            $cfg = Get-WssConfig
            $ws = Get-WssWriteStatus $cfg
            return New-WssResponse $id ([ordered]@{ tools = @(Get-WssToolDefinitions -IncludeWrite $ws.enabled -AllowOverwrite $ws.allow_overwrite -IncludeOutputSchema (Test-WssStructuredOutput)) })
        }
        'tools/call' {
            $name = $params.name
            $known = @(Get-WssToolDefinitions -IncludeWrite $true | ForEach-Object { $_.name })
            if ($known -notcontains $name) { return New-WssError $id -32602 "Unknown tool: $name" }
            $toolArgs = $params.arguments
            if ($null -eq $toolArgs) { $toolArgs = @{} }
            try {
                $result = Invoke-WssTool -Name $name -Arguments $toolArgs
                $text = ConvertTo-Json -InputObject $result -Depth 30
                $response = [ordered]@{ content = @([ordered]@{ type = 'text'; text = $text }) }
                # The text block repeats the result for clients that don't read structuredContent.
                if (Test-WssStructuredOutput) { $response.structuredContent = $result }
                $response.isError = $false
                return New-WssResponse $id $response
            } catch {
                Write-WssLog "Tool $name failed: $($_.Exception.Message)"
                return New-WssResponse $id ([ordered]@{ content = @([ordered]@{ type = 'text'; text = "Error: $($_.Exception.Message)" }); isError = $true })
            }
        }
        'resources/list' { return New-WssResponse $id ([ordered]@{ resources = @() }) }
        'prompts/list' { return New-WssResponse $id ([ordered]@{ prompts = @() }) }
        default { return New-WssError $id -32601 "Method not found: $method" }
    }
}

function Invoke-WssMessageLine {
    <# Parses one line of input and returns the serialized response line, or $null. #>
    param([string]$Line)
    if (-not $Line -or $Line.Trim() -eq '') { return $null }
    try {
        $parsed = ConvertTo-WssHashtable ($Line | ConvertFrom-Json)
    } catch {
        return ConvertTo-WssJson (New-WssError $null -32700 'Parse error')
    }
    if ($parsed -is [array]) {
        $responses = @()
        foreach ($m in $parsed) {
            if ($m -isnot [hashtable]) { $responses += New-WssError $null -32600 'Invalid Request'; continue }
            $r = Invoke-WssRequest $m
            if ($null -ne $r) { $responses += $r }
        }
        if ($responses.Count -eq 0) { return $null }
        return ConvertTo-WssJson @($responses)
    }
    if ($parsed -isnot [hashtable]) { return ConvertTo-WssJson (New-WssError $null -32600 'Invalid Request') }
    try {
        $resp = Invoke-WssRequest $parsed
    } catch {
        $rid = $null; if ($parsed.ContainsKey('id')) { $rid = $parsed.id }
        $resp = New-WssError $rid -32603 "Internal error: $($_.Exception.Message)"
    }
    if ($null -eq $resp) { return $null }
    return ConvertTo-WssJson $resp
}

function Enable-WssFakeBackend {
    <#
      Test/demo mode: loads drives, shares and query results from a JSON file instead of Windows.
      { "mappedDrives": [{"drive":"Z:","unc":"\\\\srv\\share"}],
        "shares": {"srv2": ["a","b"]},
        "results": {"SRV": [ {"System.ItemUrl": "...", ...} ]},
        "errors": {"SRV3": "message"},
        "delays": {"SRV": 1500} }   (milliseconds per query)
      Every executed SQL statement is appended to $env:WSS_FAKE_SQL_LOG when set.
    #>
    param([string]$Path)
    $data = ConvertTo-WssHashtable (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json)
    $script:FakeData = $data
    $script:FakeBackendPath = $Path
    $script:DriveProvider = {
        $out = @()
        if ($script:FakeData.mappedDrives) { foreach ($d in $script:FakeData.mappedDrives) { $out += @{ Drive = $d.drive; Unc = $d.unc } } }
        return $out
    }
    $script:ShareProvider = {
        param($HostName)
        if ($script:FakeData.shares) { foreach ($k in $script:FakeData.shares.Keys) { if ($k -ieq $HostName) { return @($script:FakeData.shares[$k]) } } }
        return @()
    }
    $script:RegistryPolicyProvider = { @($script:FakeData.registryDeny) | Where-Object { $_ } }
    $script:PolicyFileReader = {
        param($ShareUnc)
        if ($script:FakeData.policies) {
            foreach ($k in $script:FakeData.policies.Keys) {
                if ($k -ieq $ShareUnc) {
                    $v = $script:FakeData.policies[$k]
                    if ($v -is [hashtable]) { return @{ Status = 'error'; Error = $v.error } }
                    return @{ Status = 'ok'; Content = "$v" }
                }
            }
        }
        return @{ Status = 'none' }
    }
    $script:QueryExecutor = {
        param($Machine, $Sql, $Timeout)
        if ($script:FakeData.delays) { foreach ($k in $script:FakeData.delays.Keys) { if ($k -ieq $Machine) { Start-Sleep -Milliseconds ([int]$script:FakeData.delays[$k]) } } }
        if ($env:WSS_FAKE_SQL_LOG) {
            # Several runspaces may log at once.
            for ($try = 0; $try -lt 20; $try++) {
                try { [IO.File]::AppendAllText($env:WSS_FAKE_SQL_LOG, "$Machine`t$Sql`r`n", (New-Object Text.UTF8Encoding($false))); break } catch { Start-Sleep -Milliseconds 25 }
            }
        }
        if ($script:FakeData.errors) { foreach ($k in $script:FakeData.errors.Keys) { if ($k -ieq $Machine) { throw $script:FakeData.errors[$k] } } }
        if ($script:FakeData.results) { foreach ($k in $script:FakeData.results.Keys) { if ($k -ieq $Machine) { return @($script:FakeData.results[$k]) } } }
        return @()
    }
}

function Start-WssServer {
    <# Runs the MCP stdio loop: newline-delimited JSON-RPC on stdin/stdout. #>
    $utf8 = New-Object Text.UTF8Encoding($false)
    $reader = New-Object IO.StreamReader([Console]::OpenStandardInput(), $utf8)
    $writer = New-Object IO.StreamWriter([Console]::OpenStandardOutput(), $utf8)
    $writer.AutoFlush = $true
    $writer.NewLine = "`n"
    Write-WssLog "started (version $script:ServerVersion, PowerShell $($PSVersionTable.PSVersion))"
    while ($true) {
        $line = $reader.ReadLine()
        if ($null -eq $line) { break }
        $out = Invoke-WssMessageLine $line
        if ($null -ne $out) { $writer.WriteLine($out) }
    }
    Write-WssLog 'stdin closed, exiting'
}

Export-ModuleMember -Function *-Wss*
