<#
  Prepares a Windows machine (e.g. a GitHub Actions windows runner) to act as its own
  "Windows file server" with a Windows Search index:
    1. installs/enables and starts the Windows Search service (WSearch)
    2. creates a test folder with known content and adds it to the index crawl scope
    3. shares the folder via SMB and maps it as a network drive
    4. waits until the indexer has indexed the test files
  Must run elevated. Writes the test parameters to $OutFile (JSON).
#>
param(
    [string]$Folder = 'C:\wss-test',
    [string]$ShareName = 'wsstest',
    [string]$DriveLetter = 'W',
    [string]$Token = ('wsstoken' + (Get-Random -Minimum 100000 -Maximum 999999)),
    [int]$TimeoutSeconds = 600,
    [string]$OutFile = (Join-Path $PSScriptRoot 'integration-env.json')
)
$ErrorActionPreference = 'Stop'

function Step($m) { Write-Host "==> $m" }

# --- 1. Windows Search service -------------------------------------------------
Step 'Windows Search service'
$svc = Get-Service -Name WSearch -ErrorAction SilentlyContinue
if (-not $svc) {
    Step 'WSearch missing - installing Search-Service feature'
    Install-WindowsFeature -Name Search-Service | Out-Host
    $svc = Get-Service -Name WSearch -ErrorAction SilentlyContinue
    if (-not $svc) { throw 'Windows Search service could not be installed (a reboot may be required).' }
}
Set-Service -Name WSearch -StartupType Automatic
if ($svc.Status -ne 'Running') { Start-Service -Name WSearch }
(Get-Service WSearch) | Format-Table -AutoSize | Out-Host

# --- 2. Test content + crawl scope -------------------------------------------
Step "Creating test files in $Folder (token $Token)"
New-Item -ItemType Directory -Path $Folder -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $Folder 'sub folder') -Force | Out-Null
Set-Content -LiteralPath (Join-Path $Folder 'alpha.txt') -Value "The quarterly report mentions $Token and other things." -Encoding UTF8
Set-Content -LiteralPath (Join-Path $Folder 'sub folder\beta notes.txt') -Value "Meeting notes: $Token second file" -Encoding UTF8
Set-Content -LiteralPath (Join-Path $Folder "$Token-name-only.log") -Value 'nothing special here' -Encoding UTF8

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace WssSetup {
    [ComImport, Guid("AB310581-AC80-11D1-8DF3-00C04FB6EF69"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface ISearchManager {
        void _GetIndexerVersionStr(); void _GetIndexerVersion(); void _GetParameter(); void _SetParameter();
        void _get_ProxyName(); void _get_BypassList(); void _SetProxy();
        [return: MarshalAs(UnmanagedType.Interface)]
        ISearchCatalogManager GetCatalog([MarshalAs(UnmanagedType.LPWStr)] string catalog);
    }

    [ComImport, Guid("AB310581-AC80-11D1-8DF3-00C04FB6EF50"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface ISearchCatalogManager {
        void _get_Name(); void _GetParameter(); void _SetParameter(); void _GetCatalogStatus();
        void _Reset(); void _Reindex(); void _ReindexMatchingURLs();
        void ReindexSearchRoot([MarshalAs(UnmanagedType.LPWStr)] string root);
        void _put_ConnectTimeout(); void _get_ConnectTimeout(); void _put_DataTimeout(); void _get_DataTimeout();
        int NumberOfItems();
        void _NumberOfItemsToIndex(); void _URLBeingIndexed(); void _GetURLIndexingState();
        void _GetPersistentItemsChangedSink(); void _RegisterViewForNotification(); void _GetItemsChangedSink();
        void _UnregisterViewForNotification(); void _SetExtensionClusion(); void _EnumerateExcludedExtensions();
        void _GetQueryHelper(); void _put_DiacriticSensitivity(); void _get_DiacriticSensitivity();
        [return: MarshalAs(UnmanagedType.Interface)]
        ISearchCrawlScopeManager GetCrawlScopeManager();
    }

    [ComImport, Guid("AB310581-AC80-11D1-8DF3-00C04FB6EF55"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface ISearchCrawlScopeManager {
        void AddDefaultScopeRule([MarshalAs(UnmanagedType.LPWStr)] string url, [MarshalAs(UnmanagedType.Bool)] bool include, uint followFlags);
        void _AddRoot(); void _RemoveRoot(); void _EnumerateRoots(); void _AddHierarchicalScope();
        void AddUserScopeRule([MarshalAs(UnmanagedType.LPWStr)] string url, [MarshalAs(UnmanagedType.Bool)] bool include, [MarshalAs(UnmanagedType.Bool)] bool overrideChildren, uint followFlags);
        void _RemoveScopeRule(); void _EnumerateScopeRules(); void _HasParentScopeRule(); void _HasChildScopeRule();
        void _IncludedInCrawlScope(); void _IncludedInCrawlScopeEx(); void _RevertToDefaultScopes();
        void SaveAll();
    }

    public static class Indexer {
        public static void AddScope(string url) {
            Type t = Type.GetTypeFromCLSID(new Guid("7D096C5F-AC08-4F1F-BEB7-5C22C517CE39"));
            ISearchManager mgr = (ISearchManager)Activator.CreateInstance(t);
            ISearchCatalogManager cat = mgr.GetCatalog("SystemIndex");
            ISearchCrawlScopeManager scope = cat.GetCrawlScopeManager();
            scope.AddUserScopeRule(url, true, true, 0);
            scope.SaveAll();
            try { cat.ReindexSearchRoot(url); } catch (Exception) { }
        }
        public static int Count() {
            Type t = Type.GetTypeFromCLSID(new Guid("7D096C5F-AC08-4F1F-BEB7-5C22C517CE39"));
            ISearchManager mgr = (ISearchManager)Activator.CreateInstance(t);
            return mgr.GetCatalog("SystemIndex").NumberOfItems();
        }
    }
}
'@

$scopeUrl = 'file:///' + ($Folder -replace '\\', '/') + '/'
Step "Adding crawl scope $scopeUrl"
$attempt = 0
while ($true) {
    try { [WssSetup.Indexer]::AddScope($scopeUrl); break } catch {
        $attempt++
        if ($attempt -ge 10) { throw }
        Write-Host "  indexer not ready yet ($($_.Exception.Message)); retrying"
        Start-Sleep -Seconds 5
    }
}

# --- 3. SMB share + mapped drive -----------------------------------------------
Step "Sharing $Folder as \\$env:COMPUTERNAME\$ShareName"
if (Get-SmbShare -Name $ShareName -ErrorAction SilentlyContinue) { Remove-SmbShare -Name $ShareName -Force }
New-SmbShare -Name $ShareName -Path $Folder -ReadAccess 'Everyone' | Out-Null
$unc = "\\$env:COMPUTERNAME\$ShareName"
Step "Mapping ${DriveLetter}: -> $unc"
cmd /c "net use ${DriveLetter}: /delete /y" 2>$null | Out-Null
cmd /c "net use ${DriveLetter}: $unc /persistent:no" | Out-Host
if ($LASTEXITCODE -ne 0) { throw "net use failed with exit code $LASTEXITCODE" }

# --- 4. Wait for indexing -------------------------------------------------------
Step 'Waiting for the indexer'
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$localSql = "SELECT System.ItemPathDisplay FROM SystemIndex WHERE SCOPE='file:$($Folder -replace '\\','/')' AND CONTAINS(*, '`"$Token`"')"
$found = 0
while ((Get-Date) -lt $deadline) {
    $conn = New-Object -ComObject ADODB.Connection
    try {
        $conn.Open("Provider=Search.CollatorDSO;Extended Properties='Application=Windows';")
        $rs = $conn.Execute($localSql)
        $found = 0
        while (-not $rs.EOF) { $found++; $rs.MoveNext() }
        $rs.Close()
    } catch { Write-Host "  query failed: $($_.Exception.Message)" } finally { try { $conn.Close() } catch { } }
    Write-Host ("  indexed items with token: {0} (catalog total {1})" -f $found, $(try { [WssSetup.Indexer]::Count() } catch { '?' }))
    if ($found -ge 2) { break }
    Start-Sleep -Seconds 10
}
if ($found -lt 2) { throw "Indexer did not index the test files within $TimeoutSeconds s" }

@{
    Token = $Token; Folder = $Folder; Share = $ShareName; Unc = $unc
    Drive = "${DriveLetter}:"; Computer = $env:COMPUTERNAME
} | ConvertTo-Json | Set-Content -LiteralPath $OutFile -Encoding UTF8
Step "Done. Environment written to $OutFile"
