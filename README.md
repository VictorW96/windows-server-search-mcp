# Windows Server Search MCP

A local [MCP](https://modelcontextprotocol.io) server, packaged as a **Claude plugin** for Claude Cowork,
Claude Desktop and Claude Code. Claude can search Windows file servers through **their own Windows Search
index**, and read the files it finds.

- **Zero setup on a typical company PC:** the server finds the network drives already mapped on the machine
  (`Z:` → `\\fileserver\projects`) and makes every Windows server behind them searchable.
- **Fast, full-text search:** uses Windows Search remote queries (`SELECT … FROM FILESERVER.SystemIndex
  WHERE SCOPE='file://FILESERVER/share'`), so even large shares answer in milliseconds. Results include
  content matches, metadata and relevance rank.
- **No dependencies:** pure PowerShell (Windows PowerShell 5.1, which ships with Windows, or PowerShell 7),
  using the built-in `Search.CollatorDSO` OLE DB provider. No Node.js, Python or modules needed.

## Install (Claude Cowork / Desktop / Code)

The plugin is published in the marketplaces [VictorW96/agentic-marketplace](https://github.com/VictorW96/agentic-marketplace)
and [PMI-ING/marketplace](https://github.com/PMI-ING/marketplace) (install it as
`windows-server-search@pmi-ing-marketplace`). Add only one of them.

- **Cowork / Claude Desktop:** *Customize → Plugins → Add marketplace* → `VictorW96/agentic-marketplace`, then
  install **windows-server-search**.
- **Claude Code:**
  ```
  /plugin marketplace add VictorW96/agentic-marketplace
  /plugin install windows-server-search@agentic-marketplace
  ```

The MCP server runs locally on the Windows host. Cowork starts plugin MCP servers on the host, not in its VM,
so the server sees your mapped drives and Windows credentials.

## Tools

| Tool | Purpose |
|---|---|
| `list_servers` | Servers/shares available (discovered + configured) with drive letters; `check: true` tests each index |
| `search_files` | Index search: `query` (words, `"phrases"`, `-exclude`, `OR`), `match` (all/filename/contents), `server`, `path` (`Z:\folder` or UNC), `extensions`, `kind`, `author`, `modified_after/before`, `sort`, `max_results`, `offset` (paging via `next_offset`), `snippets` (text around the match for the first 10 results) |
| `read_file` | Text of a file on a known share, chunked via `offset`; with `find`, only the matching passages (with line numbers and offsets). Formats: see [Reading files](#reading-files) |
| `list_directory` | Folder listing on a known share |
| `copy_file` | Copies one or more files (any format) from a share to a **local** folder, e.g. the Cowork workspace, so Claude can work on PDFs, images and spreadsheets with its own tools |

`read_file`, `list_directory` and `copy_file` only accept source paths inside the discovered or configured shares.

Dates in results are UTC (`…Z`). `modified_after` / `modified_before` accept dates and times with `Z` or an offset;
without one they mean the local time of the PC, and a plain date covers that whole day
(`modified_before: 2024-12-31` includes 31 December).

For clients on MCP protocol 2025-06-18 or newer, every tool declares an `outputSchema` and returns its result as
`structuredContent` as well as JSON text.

| `save_file` | Saves text (`content`) or workspace files to a server folder (on by default, can be disabled). No delete, move or rename |

### Reading files

- **Text formats** (`.txt`, `.csv`, `.md`, code, …) as they are; UTF-8, UTF-16 and BOMs are detected.
- **Word** (`.docx`, `.docm`, `.dotx`): body text, tables (cells tab-separated, one row per line), headers and
  footers, footnotes, endnotes and comments (with author). Deleted tracked changes and field codes are left out.
- **Excel** (`.xlsx`, `.xlsm`, `.xltx`): one block per sheet with its real name, in workbook order (hidden sheets
  are marked), one line per row starting with the row number. Empty cells keep their column, so values stay
  under their headers. Dates, times, durations, percentages and booleans are shown as such, not as raw numbers.
- **PowerPoint** (`.pptx`, `.ppsx`, `.potx`): slides in presentation order, with speaker notes.
- **Everything else through Windows filters (IFilter):** the components Windows Search itself uses to read
  file contents. Windows ships filters for legacy Office files (`.doc`, `.xls`, `.ppt`), `.rtf`, `.eml`/`.mht`
  and more; PDF needs a PDF filter, which Adobe Acrobat Reader and other PDF readers install; Outlook adds
  `.msg`. If a format has no filter on the PC, `read_file` says so and suggests `copy_file`. Scanned PDFs without
  a text layer have no text to read.
  Filters run inside the MCP server process on their own thread with a time limit (`filterTimeout`, 60 s).
  Windows Search runs them in an isolated host process instead; if you'd rather not run them in-process,
  set `"useIFilter": false` in the config file (or `WSS_USE_IFILTER=false`).

`find` in `read_file` searches the whole extracted text: case-insensitive, line breaks count as spaces, and
`a OR b` finds either. Each passage has the matching line(s) plus `context` lines around them, its line
number, and its `offset`, which `read_file` accepts to read on from there.

### Writing to servers (`save_file`, on by default)

Writing and overwriting are **enabled by default**. Claude can save files to every known share except
blocked paths. When it replaces a file (`overwrite: true`), the previous version is always kept as a backup.
To restrict this:

```json
// %APPDATA%\windows-server-search-mcp\config.json  (Cowork)  – or plugin options allow_write / allow_overwrite (Claude Code)
{ "write": { "enabled": false } }   // either: turn writing off completely
{ "write": { "allowOverwrite": false, "maxMB": 100, "logPath": "\\\\fs01\\it\\claude-writes.jsonl" } } // or: never replace files + central log
```

- **Group Policy veto:** `DisableWrite = 1` (DWORD) under `HKLM\SOFTWARE\Policies\WindowsServerSearchMcp`
  (or HKCU) turns writing off whatever the user configured. The tool then disappears.
- **Disabled means hidden:** the tool isn't listed at all while writing is disabled. A change takes
  effect in the next session.
- **Never writable:**
  - blocked paths from the access policy;
  - `.claude-policy` files;
  - programs and scripts (`.exe .dll .com .scr .msi .bat .cmd .ps1 .vbs .js .hta .lnk .url .reg .jar` …),
    plus `desktop.ini` and `autorun.inf`;
  - names reserved by Windows.
- **Sources:**
  - inline text (`content` + `name`, encoding `utf8`, `utf8-bom` or `utf16`);
  - files from the Cowork workspace (`source_marker` + `source_name(s)`), the configured download folder,
    or the default download folder.
  
  Other local files can't be uploaded, so a manipulated prompt can't send arbitrary PC files to a server.
  Hidden files and dot folders (`.ssh`, `.env`, …) are refused, and so are password vaults and certificates
  (`*.kdbx`, `*.pfx`, …), even when renamed.
- **No silent overwrites:**
  - an existing file gets a numbered copy (`report (1).docx`);
  - `overwrite: true` replaces it (unless `allowOverwrite` is `false`), and the previous version is kept
    as `report.docx.claude-backup-<yyyyMMdd-HHmmss>` (the save's date and time). The new version and the
    backup both keep the original file's NTFS permissions. If the file has its own (non-inherited)
    permissions and the share doesn't allow carrying them over (share permission "Change" instead of
    "Full Control"), the overwrite is refused rather than leaving the content more widely readable.
- **No half-written files:** content goes to a hidden temp file in the target folder and is then renamed.
- **Audit log:** each write is a JSON line (time, user, computer, source, target, size, overwritten, backup)
  in `%LOCALAPPDATA%\windows-server-search-mcp\write-log.jsonl`, or in `logPath`, which may be a central
  share.
- **NTFS permissions apply:** files are written with the user's own Windows permissions, just like Explorer.

### Copying files into the Cowork workspace

The MCP server runs on Windows. Claude sees its Cowork workspace folder only at its path inside the VM,
not at the Windows path. `copy_file` bridges the two with a marker file:

1. Claude creates an empty file with a random name starting with `.wss-`, e.g. `.wss-target-7f3k9q2m`, in its
   workspace folder.
2. Claude calls `copy_file` with `destination_marker: ".wss-target-7f3k9q2m"`.
3. The server searches the user profile and OneDrive folders for the marker. It skips `AppData`, hidden
   folders and links, and caches the result per session. The files are copied next to the marker.
   A marker directly in the user profile, the OneDrive folder or a top-level folder such as `Documents` or
   `Desktop` is refused, so the workspace must be a dedicated folder.

Alternatively, pass `destination` as a Windows path, or set the **Download folder** plugin option.
Copies never overwrite existing files unless `overwrite: true`; a numbered copy is created instead.
Copies never go to UNC paths or network drives, and each file has a size limit (`WSS_MAX_COPY_MB`, default 500).
They never go to system, program or configuration folders either: Windows, Program Files, ProgramData,
`AppData` (except the temp folder), dot folders in the user profile (`.ssh`, `.claude`, …), the PowerShell
profile folders, the user profile itself or a drive root. Programs and scripts (`.exe`, `.ps1`, `.bat`, …) are
only copied into the workspace (marker) or the download folder, not to another `destination`.

## Access policy (blocked paths)

You can block folders and files with wildcard patterns. Claude can't **find, list, read or copy** what they
match. Search reports how many matches were hidden (`hidden_by_policy`), so the user knows something was
withheld. Rules come from five sources and are combined. A source can only *add* blocks, never remove
blocks set elsewhere:

| Source | Maintained by | Setup on client PCs |
|---|---|---|
| **`.claude-policy` file in the root of a share**, gitignore style ([example](examples/.claude-policy)) | File server admins; protect it with NTFS permissions | **None.** Picked up automatically and re-read every 5 minutes (`WSS_POLICY_TTL`) |
| **Group Policy / Intune**: registry value `DenyPaths` (REG_MULTI_SZ or `;`-separated) under `HKLM\SOFTWARE\Policies\WindowsServerSearchMcp` (or HKCU\…\Policies) | IT, centrally; users cannot write these keys | **None.** Deployed centrally |
| **Your own `.claude-policy`**: `%APPDATA%\windows-server-search-mcp\.claude-policy`, same gitignore style, applies to every share | The user | **None.** Created empty (comments only) when the plugin first starts; changes apply immediately |
| **Plugin option "Blocked paths"** (`WSS_DENY`) | The user (Claude Code) | Optional |
| **Built-in**: `$RECYCLE.BIN`, `System Volume Information`, `*.kdbx`, `*.kdb`, `*.pfx`, `*.p12`, `~$*` | – | None |

**Pattern syntax** (case-insensitive; `/` and `\` are interchangeable):

- `*` matches within one name, `?` matches one character, and `**` matches any number of folders.
- A pattern that matches a folder blocks everything below it.
- Global patterns (Group Policy and the plugin option) can be:
  - server paths like `\\fs01\hr`, `\\*\hr\**` or `\\fs01\projects\*\Contracts`;
  - drive paths like `Z:\Finance`;
  - floating patterns like `**\Personal`, `*.kdbx` or `Personal`, which match at any depth on every share.
- In a `.claude-policy` file, patterns follow gitignore rules relative to the share:
  - `name` matches at any depth;
  - `/name` and `a/b` are anchored to the share root.
  
  Your own `.claude-policy` in `%APPDATA%` uses the same rules, relative to the root of **every** share.
  It also accepts server paths (`\\fs01\hr`) and drive paths (`Z:\Finance`).
  `!` negations are not supported.

Example Group Policy deployment (or the same value through Intune / GPO preferences):

```
reg add HKLM\SOFTWARE\Policies\WindowsServerSearchMcp /v DenyPaths /t REG_MULTI_SZ /d "\\fs01\hr\0**\Personal\0**\*.kdbx" /f
```

**How it is enforced:**

- **Path normalisation:** paths are normalised before matching. The server name is reduced to its short
  name, which also covers the full domain name. `..` segments, trailing dots and spaces, and `:stream`
  suffixes are handled. 8.3 short names like `CONFID~1` are expanded.
- **Links:** for reads, copies and listings, symbolic links that Windows follows on the client are resolved,
  and the real target is checked too.
- **Fail closed:** if a share's `.claude-policy` exists but can't be read or parsed, that whole share is
  blocked, and `list_servers` explains why. If your own `.claude-policy` can't be read or parsed, all shares
  are blocked. A single pattern that can't be used (e.g. an unmapped drive letter) is only reported.
- **Search filtering:** search first examines `3 × (offset + max_results + 1) + 20` index hits per server (at
  most 2000). If blocked files crowd out the allowed ones, it asks the index for more, up to 5000 hits.
  `hidden_by_policy` counts the blocked hits among those examined.
- **`list_servers`** shows the active rules per source, the policy files it found, and any blocked shares.

- **Known shares only:** the `path` filter of `search_files` must lie inside a discovered or configured share.
  Other shares of the same server, whose `.claude-policy` the plugin doesn't load, and excluded shares can't
  be searched.

**Limits:** this is a guardrail for Claude, not a security boundary.

- The user can still open these files themselves. Use NTFS permissions for real protection; Windows Search
  already only returns files the user may read.
- Junctions on the server are resolved server-side, so the client can't see where they lead. Block the
  junction's own path as well.
- If a server is reachable under an alias, such as a DNS alias or an IP address, use `\\*\share` patterns
  or floating patterns.

## Configuration

All settings are optional. A PC with mapped network drives works without any configuration.

**Where to set them:**

- **Claude Code:** `claude plugin configure windows-server-search`, or `/plugin` → the plugin → configure.
- **Claude Cowork:** Cowork has no UI for plugin options and always uses the defaults.
  ([docs](https://claude.com/docs/plugins/platform-support): "Cowork doesn't prompt for values")
  Use the config file instead:
  `%APPDATA%\windows-server-search-mcp\config.json`. It needs no admin rights; see the
  [example](examples/config.json). The server reads it at every tool call, so changes apply immediately.
- **Blocked paths:** `%APPDATA%\windows-server-search-mcp\.claude-policy`, gitignore style; see
  [Access policy](#access-policy-blocked-paths).
- **Company-wide:** blocked paths come from Group Policy or `.claude-policy` files on the shares; see
  [Access policy](#access-policy-blocked-paths).

**How the sources combine:**

- List settings (`servers`, `exclude`) from the plugin options and the config file are merged. A `deny`
  list in older config files is still honoured; new rules belong in `.claude-policy`.
- For single values (`autoDiscover`, `maxResults`, `downloadDir`, …) the **config file wins** over the
  plugin options, because Cowork always passes the defaults.
- `copy_file` refuses to write into the config folder.

| Plugin option | Config file key / env variable | Default | Meaning |
|---|---|---|---|
| Additional servers / shares | `servers` / `WSS_SERVERS` | – | `;`-separated UNC paths, e.g. `\\fs01\projects;\\fs02`. A bare server searches all its shares (via `net view`) |
| Use mapped network drives | `autoDiscover` / `WSS_AUTO_DISCOVER` | `true` | Auto-discover servers from mapped drives (CIM `Win32_LogicalDisk`, `HKCU\Network`, PSDrives) |
| Exclude servers / shares | `exclude` / `WSS_EXCLUDE` | – | `;`-separated server names or UNC shares to ignore |
| Blocked paths | `WSS_DENY` | – | `;`-separated wildcard patterns; in Cowork use `.claude-policy` instead, see [Access policy](#access-policy-blocked-paths) |
| – | `policyTtl` / `WSS_POLICY_TTL` | `300` | Seconds to cache share `.claude-policy` files |
| Default maximum results | `maxResults` / `WSS_MAX_RESULTS` | `50` | 1–500 |
| Download folder | `downloadDir` / `WSS_DOWNLOAD_DIR` | `%USERPROFILE%\Downloads\Windows Server Search` | Default destination for `copy_file` |
| – | `maxCopyMB` / `WSS_MAX_COPY_MB` | `500` | Maximum size per copied file |
| Allow writing to servers | `write.enabled` / `WSS_WRITE_ENABLED` | `true` | `save_file`; set `false` to disable |
| Allow overwriting files | `write.allowOverwrite` / `WSS_WRITE_OVERWRITE` | `true` | `overwrite: true` replaces files (with backup); `false` = numbered copies only |
| – | `write.maxMB` / `WSS_WRITE_MAX_MB` | `100` | Maximum size per written file |
| – | `write.logPath` / `WSS_WRITE_LOG` | `%LOCALAPPDATA%\windows-server-search-mcp\write-log.jsonl` | Write audit log |
| – | `queryTimeout` / `WSS_QUERY_TIMEOUT` | `30` | Seconds per index query. Several servers are queried in parallel |
| – | `discoveryTtl` / `WSS_DISCOVERY_TTL` | `60` | Seconds to reuse the discovered servers and shares between tool calls; `list_servers` always rediscovers. `0` = discover on every call |
| – | `useIFilter` / `WSS_USE_IFILTER` | `true` | Read PDF, `.doc`, `.rtf`, `.msg` … through Windows filters, see [Reading files](#reading-files) |
| – | `filterTimeout` / `WSS_FILTER_TIMEOUT` | `60` | Seconds per Windows filter run |
| – | `useNetBios` / `WSS_USE_NETBIOS` | `true` | Query FQDN hosts by their NetBIOS name, which Windows Search requires |
| – | `WSS_CONFIG_FILE` | `%APPDATA%\windows-server-search-mcp\config.json` | JSON file with `servers`, `exclude`, `autoDiscover`, `maxResults`, …; the user's `.claude-policy` is read from the same folder |

### Server requirements

Remote index queries need the **Windows Search Service** on the file server. On Windows Server, install it
with `Install-WindowsFeature Search-Service`. The service must index the shared folders, so add them under
*Indexing Options*. Results are security-trimmed to the current user. If a server has no index, `list_servers`
with `check: true` reports why, and `read_file` / `list_directory` still work.

## Development

```
server/            MCP server (WindowsServerSearch.psm1 = logic, server.ps1 = stdio entry point)
plugin/            plugin template (manifest, .mcp.json, skill)
tests/             Pester unit tests + stdio end-to-end test (fake backend, any OS)
tests/integration/ real Windows Search tests (Windows, admin)
scripts/           build.sh, release.sh, update_marketplace.py
```

### Testing strategy

Most of us have no Windows file server at hand, so the tests run in three layers:

1. **Unit tests** (`tests/WindowsServerSearch.Tests.ps1`): config parsing, drive/share discovery and its
   cache (backend injected), `net view` parsing (English and German), SQL generation and escaping, date
   filters, paging, path resolution and traversal protection, Office text extraction (sparse spreadsheet rows,
   number formats, Word tables and notes, slide order), Windows filter handling (extractor injected),
   `find` passages, snippets, and the MCP protocol including structured output.
2. **stdio end-to-end** (`tests/StdioServer.Tests.ps1`): launches `server.ps1` as a process and speaks
   JSON-RPC over stdin/stdout against a fake backend (`WSS_FAKE_BACKEND=fake.json`, SQL logged to
   `WSS_FAKE_SQL_LOG`). With four slow fake servers (`delays`), it checks that they are queried in parallel.
3. **Real Windows Search** (`tests/integration`, CI on `windows-2022` / `windows-2025`): the runner acts as
   its own file server. `Setup-WindowsSearch.ps1` enables `WSearch`, creates test files, adds them to the
   crawl scope over COM, shares the folder over SMB and maps it as drive `W:`. The tests then start the real
   server under both `powershell.exe` 5.1 and `pwsh` 7. They check that the drive is auto-discovered and run
   **remote-syntax** queries (`RUNNER.SystemIndex` + `file://RUNNER/wsstest`), `read_file`,
   `list_directory` and `copy_file`. The `copy_file` checks include a simulated Cowork workspace found via
   the marker file, a batch copy with per-file errors, and refusing to write to the network drive.
   The access policy checks use a real `.claude-policy` file on the share and a real Group Policy registry
   value. They verify that search hides blocked files and reports the exact hidden count, that listings hide
   blocked entries, and that read and copy are refused. They also try to get around the rules with a
   trailing-dot path, an 8.3 short name and a client-evaluated symlink.
   The `save_file` checks write to the share and verify the files directly in the server folder. They cover
   numbered copies, overwriting with a backup, and an upload from the workspace. They check that
   executables, blocked folders, `.claude-policy`, foreign local sources and non-share targets are refused,
   that every write is logged, that the tool is available by default and hidden when disabled, and that the
   Group Policy veto works.
   A second session reads a spreadsheet, an RTF file (through the real Windows filter, when the runner has one)
   and a long text file with `find` from the share, and checks search snippets and structured output.

Run locally (any OS with PowerShell 7 or Docker):

```bash
pwsh -c 'Invoke-Pester ./tests -Output Detailed'
# or in Docker; the .NET SDK image includes pwsh and also runs natively on Apple Silicon
# (mcr.microsoft.com/powershell is amd64-only and crashes under emulation there)
docker run --rm -v "$PWD":/w -w /w mcr.microsoft.com/dotnet/sdk:8.0 \
  pwsh -c 'Install-Module Pester -MinimumVersion 5.5.0 -Force; Invoke-Pester ./tests -Output Detailed'
```

To try it on a real Windows PC with mapped drives:

```powershell
'{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_servers","arguments":{"check":true}}}' |
  powershell -NoProfile -ExecutionPolicy Bypass -File server\server.ps1
```

### Build and release

```bash
scripts/build.sh      # -> dist/windows-server-search/ + .zip, validated with `claude plugin validate`
scripts/release.sh    # build, tag v$(cat VERSION), GitHub release, publish into the marketplace repos
```

To release: bump `VERSION`, commit, run `scripts/release.sh`. It publishes to every repo in `MARKETPLACE_REPOS`
(default `VictorW96/agentic-marketplace PMI-ING/marketplace`) and needs `gh` with push access to all of them.
Pushing a `v*` tag also runs the CI `release` job. That job publishes to the marketplaces when the
`MARKETPLACE_TOKEN` secret holds a token with write access to every marketplace repo.

## License

MIT
