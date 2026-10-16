# AGENTS.md

Notes for coding agents working on this repository. The [README](README.md) describes what the plugin does
and how it is configured; this file covers how to change, test and release it.

## Layout

```
server/WindowsServerSearch.psm1   all logic (discovery, SQL, policy, file readers, MCP protocol)
server/server.ps1                 stdio entry point (imports the module, starts the loop)
plugin/                           plugin template: manifest, .mcp.json, skill (SKILL.md)
tests/WindowsServerSearch.Tests.ps1   Pester unit tests (any OS)
tests/StdioServer.Tests.ps1          launches server.ps1 and speaks JSON-RPC (any OS, fake backend)
tests/integration/                   real Windows Search, SMB share, Group Policy (Windows CI only)
scripts/                          build.sh, release.sh, update_marketplace.py
```

## Running the tests

Unit and stdio tests run anywhere PowerShell 7 runs (about 3 seconds):

```bash
pwsh -c 'Invoke-Pester ./tests -Output Detailed'
```

### On an ARM machine (Apple Silicon) with Docker

Don't use `mcr.microsoft.com/powershell`: it is amd64-only, and under emulation .NET crashes with
`qemu: uncaught target signal 11 (Segmentation fault)`. Use the .NET SDK image instead. It ships `pwsh` and has
a native arm64 build. A named volume keeps Pester installed between runs:

```bash
docker run --rm --platform linux/arm64 \
  -v "$PWD":/w -w /w \
  -v wss-psmodules:/root/.local/share/powershell/Modules \
  mcr.microsoft.com/dotnet/sdk:8.0 pwsh -NoProfile -c '
    if (-not (Get-Module -ListAvailable Pester | Where-Object Version -ge 5.5.0)) {
      Set-PSRepository PSGallery -InstallationPolicy Trusted
      Install-Module Pester -MinimumVersion 5.5.0 -Force -Scope CurrentUser
    }
    $c = New-PesterConfiguration
    $c.Run.Path = "./tests/WindowsServerSearch.Tests.ps1", "./tests/StdioServer.Tests.ps1"
    $c.Output.Verbosity = "Normal"
    $c.Output.RenderMode = "Plaintext"
    Invoke-Pester -Configuration $c'
```

- Leave out `tests/integration`: those tests need Windows and are skipped elsewhere anyway.
- When a script inside the container starts a child PowerShell, use `(Get-Process -Id $PID).Path` (as the stdio
  tests do), not `pwsh`. In this image, a bare `pwsh` from a script can resolve to an x64 shim and fail with
  `rosetta error: failed to open elf at /lib64/ld-linux-x86-64.so.2`.
- A parse check of every script (catches syntax errors in files the local run doesn't execute):
  ```bash
  docker run --rm --platform linux/arm64 -v "$PWD":/w -w /w mcr.microsoft.com/dotnet/sdk:8.0 pwsh -NoProfile -c '
    Get-ChildItem -Recurse -Include *.ps1,*.psm1 | Where-Object FullName -notmatch "[\\/]dist[\\/]" | ForEach-Object {
      $e = $null; $t = $null
      [void][System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$t, [ref]$e)
      "{0}: {1} errors" -f $_.Name, $e.Count }'
  ```
- C# embedded through `Add-Type` (the IFilter interop, `GetFinalPathNameByHandle`) also compiles on Linux, so a
  compile check works locally. Calling it needs Windows.

### What only Windows CI can check

Windows PowerShell 5.1, COM (ADODB / `Search.CollatorDSO`), Windows filters (IFilter, `query.dll`), symlinks
and 8.3 names on SMB, Group Policy registry values, and the runspace pool on Windows. Run CI before every
release (see below).

## Compatibility rules

The server must run under **Windows PowerShell 5.1** (`powershell.exe`, what `.mcp.json` starts) and PowerShell 7.

- **ASCII only in `server/`.** 5.1 reads BOM-less scripts in the ANSI code page. Write non-ASCII characters
  as `[char]0x2026`. `scripts/build.sh` refuses non-ASCII server files.
- **Non-ASCII in tests:** a literal like `'…'` in a test file is garbled on 5.1 too. Comparing two values from
  the same file is fine; comparing against module output is not. Use regex escapes such as `…`.
- **Embedded C# must be C# 5** (the .NET Framework compiler): no `$"..."`, `?.`, `=>` members or `out var`.
- **`StringBuilder.AppendLine` writes CRLF on Windows.** Text returned to Claude uses `\n` on every platform.
- **`ConvertFrom-Json` types differ:** 5.1 returns `[int]` where 7 returns `[long]`. Don't assert one of them.
- **`$Matches`** is an automatic variable. Don't name a local variable `$matches`.
- **Execution policies only exist on Windows.** Setting `InitialSessionState.ExecutionPolicy` elsewhere makes
  `RunspacePool.Open()` fail with "Operation is not supported on this platform".

## Code conventions

- Functions are `Verb-Wss<Noun>` and exported through `Export-ModuleMember -Function *-Wss*`.
- stdout carries JSON-RPC only. Log with `Write-WssLog`, which writes to stderr.
- Tool errors are thrown as exceptions. `Invoke-WssRequest` turns them into `isError: true` results, so put
  the hint for the user and for Claude in the message.
- **Test seams:** module-scope scriptblocks replace Windows-only parts:
  - `$script:QueryExecutor`, `$script:DriveProvider`, `$script:ShareProvider`;
  - `$script:RegistryPolicyProvider`, `$script:PolicyFileReader`;
  - `$script:IFilterExtractor`.

  Unit tests set them through `Set-TestBackend` (which also resets the caches); the stdio tests use
  `WSS_FAKE_BACKEND=<json>` (see `Enable-WssFakeBackend`, including per-server `delays`).
- **Parallel search:** with several servers, `Invoke-WssServerSearches` runs `Search-WssServer` in a runspace
  pool. Runspaces can't use scriptblocks injected into the main session, so with `Set-TestBackend` the search
  runs one server after another; only the fake backend file works in parallel. `Search-WssServer` must only use
  its parameters and never throw.
- **Access policy:** every new way to reach a file goes through `Resolve-WssPath` (known shares only) and
  `Assert-WssAllowed` (use `-CheckFinalPath` when reading). Search results are filtered with `Test-WssBlocked`.
  The policy only ever adds blocks.
- New settings go into `Get-WssConfig` (environment variable + config-file key, file wins for single values),
  the README table and, if users of Claude Code should set them, `plugin/.claude-plugin/plugin.json` +
  `plugin/.mcp.json`.
- **Changes Claude should know about** go into three places:
  - the tool descriptions in `Get-WssToolDefinitions`;
  - the output schemas in `Get-WssOutputSchemas`;
  - the skill, `plugin/skills/windows-server-search/SKILL.md`.

## CI

`.github/workflows/ci.yml` runs on pushes to `main`, on `v*` tags, on pull requests, and manually. A push to
another branch starts nothing, so start it there yourself:

```bash
gh workflow run ci.yml --ref <branch>
gh run list --branch <branch> --limit 1          # get the run id
gh run watch <id> --exit-status
gh run view <id> --log-failed                    # failing tests
```

The jobs:
- unit + stdio tests: pwsh on Ubuntu, pwsh 7 and powershell 5.1 on Windows;
- real Windows Search integration tests on `windows-2022` and `windows-2025`;
- plugin build + `claude plugin validate`;
- on tags: publishing to the marketplaces.

## Build and release

```bash
scripts/build.sh      # dist/windows-server-search + zip, validated with `claude plugin validate`
scripts/release.sh    # build, tag v$(cat VERSION), GitHub release, publish to every marketplace
```

1. Work on a branch, get CI green on it, then merge into `main` (fast-forward).
2. On `main`: put the new version in `VERSION`, commit as `Release X.Y.Z`, push.
3. Run `scripts/release.sh` from a clean `main`. It needs `gh` with push access to this repository and to
   every repository in `MARKETPLACE_REPOS` (default `VictorW96/agentic-marketplace PMI-ING/marketplace`).
4. Check that both marketplaces list the version:
   ```bash
   for r in VictorW96/agentic-marketplace PMI-ING/marketplace; do
     gh api repos/$r/contents/.claude-plugin/marketplace.json --jq .content | base64 -d | grep -A2 windows-server-search
   done
   ```

The tag push also starts the CI `release` job. It runs the same script and finds the marketplaces already up to
date.
