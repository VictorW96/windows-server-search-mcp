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
and [PMI-ING/agentic-marketplace](https://github.com/PMI-ING/agentic-marketplace) (install it as
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
| `search_files` | Index search: `query` (words, `"phrases"`, `-exclude`, `OR`), `match` (all/filename/contents), `server`, `path` (`Z:\folder` or UNC), `extensions`, `kind`, `author`, `modified_after/before`, `sort`, `max_results` |
| `read_file` | Text of a file on a known share: text formats, `.docx`, `.xlsx`, `.pptx`; chunked via `offset` |
| `list_directory` | Folder listing on a known share |
| `copy_file` | Copies one or more files (any format) from a share to a **local** folder, e.g. the Cowork workspace, so Claude can work on PDFs, images and spreadsheets with its own tools |

`read_file`, `list_directory` and `copy_file` only accept source paths inside the discovered or configured shares.

| `save_file` | Saves text (`content`) or workspace files to a server folder (on by default, can be disabled). No delete, move or rename |

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
withheld. Rules come from four sources and are combined. A source can only *add* blocks, never remove
blocks set elsewhere:

| Source | Maintained by | Setup on client PCs |
|---|---|---|
| **`.claude-policy` file in the root of a share**, gitignore style ([example](examples/.claude-policy)) | File server admins; protect it with NTFS permissions | **None.** Picked up automatically and re-read every 5 minutes (`WSS_POLICY_TTL`) |
| **Group Policy / Intune**: registry value `DenyPaths` (REG_MULTI_SZ or `;`-separated) under `HKLM\SOFTWARE\Policies\WindowsServerSearchMcp` (or HKCU\…\Policies) | IT, centrally; users cannot write these keys | **None.** Deployed centrally |
| **Plugin option "Blocked paths"** (`WSS_DENY`) | The user | Optional |
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
  blocked, and `list_servers` explains why.
- **Search filtering:** search examines `3 × max_results + 20` index hits, and up to 5000 if needed, so
  blocked files don't crowd out allowed ones. `hidden_by_policy` counts the blocked hits among those
  examined.
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
- **Company-wide:** blocked paths come from Group Policy or `.claude-policy` files on the shares; see
  [Access policy](#access-policy-blocked-paths).

**How the sources combine:**

- List settings (`servers`, `exclude`, `deny`) from the plugin options and the config file are merged.
- For single values (`autoDiscover`, `maxResults`, `downloadDir`, …) the **config file wins** over the
  plugin options, because Cowork always passes the defaults.
- `copy_file` refuses to write into the config folder.

| Plugin option | Config file key / env variable | Default | Meaning |
|---|---|---|---|
| Additional servers / shares | `servers` / `WSS_SERVERS` | – | `;`-separated UNC paths, e.g. `\\fs01\projects;\\fs02`. A bare server searches all its shares (via `net view`) |
| Use mapped network drives | `autoDiscover` / `WSS_AUTO_DISCOVER` | `true` | Auto-discover servers from mapped drives (CIM `Win32_LogicalDisk`, `HKCU\Network`, PSDrives) |
| Exclude servers / shares | `exclude` / `WSS_EXCLUDE` | – | `;`-separated server names or UNC shares to ignore |
| Blocked paths | `deny` / `WSS_DENY` | – | `;`-separated wildcard patterns; see [Access policy](#access-policy-blocked-paths) |
| – | `policyTtl` / `WSS_POLICY_TTL` | `300` | Seconds to cache share `.claude-policy` files |
| Default maximum results | `maxResults` / `WSS_MAX_RESULTS` | `50` | 1–500 |
| Download folder | `downloadDir` / `WSS_DOWNLOAD_DIR` | `%USERPROFILE%\Downloads\Windows Server Search` | Default destination for `copy_file` |
| – | `maxCopyMB` / `WSS_MAX_COPY_MB` | `500` | Maximum size per copied file |
| Allow writing to servers | `write.enabled` / `WSS_WRITE_ENABLED` | `true` | `save_file`; set `false` to disable |
| Allow overwriting files | `write.allowOverwrite` / `WSS_WRITE_OVERWRITE` | `true` | `overwrite: true` replaces files (with backup); `false` = numbered copies only |
| – | `write.maxMB` / `WSS_WRITE_MAX_MB` | `100` | Maximum size per written file |
| – | `write.logPath` / `WSS_WRITE_LOG` | `%LOCALAPPDATA%\windows-server-search-mcp\write-log.jsonl` | Write audit log |
| – | `queryTimeout` / `WSS_QUERY_TIMEOUT` | `30` | Seconds per index query |
| – | `useNetBios` / `WSS_USE_NETBIOS` | `true` | Query FQDN hosts by their NetBIOS name, which Windows Search requires |
| – | `WSS_CONFIG_FILE` | `%APPDATA%\windows-server-search-mcp\config.json` | JSON file with `servers`, `exclude`, `autoDiscover`, `maxResults`, … |

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

1. **Unit tests** (`tests/WindowsServerSearch.Tests.ps1`): config parsing, drive/share discovery
   (backend injected), `net view` parsing (English and German), SQL generation and escaping,
   path resolution and traversal protection, Office text extraction, and the MCP protocol.
2. **stdio end-to-end** (`tests/StdioServer.Tests.ps1`): launches `server.ps1` as a process and speaks
   JSON-RPC over stdin/stdout against a fake backend (`WSS_FAKE_BACKEND=fake.json`, SQL logged to
   `WSS_FAKE_SQL_LOG`).
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

Run locally (any OS with PowerShell 7 or Docker):

```bash
pwsh -c 'Invoke-Pester ./tests -Output Detailed'
# or
docker run --rm -v "$PWD":/w -w /w mcr.microsoft.com/powershell \
  pwsh -c 'Install-Module Pester -Force; Invoke-Pester ./tests -Output Detailed'
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
(default `VictorW96/agentic-marketplace PMI-ING/agentic-marketplace`) and needs `gh` with push access to all of them.
Pushing a `v*` tag also runs the CI `release` job. That job publishes to the marketplaces when the
`MARKETPLACE_TOKEN` secret holds a token with write access to every marketplace repo.

## License

MIT
