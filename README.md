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

The plugin is published in the marketplace [VictorW96/agentic-marketplace](https://github.com/VictorW96/agentic-marketplace).

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

### Copying files into the Cowork workspace

The MCP server runs on Windows. Claude sees its Cowork workspace folder only at its path inside the VM,
not at the Windows path. `copy_file` bridges the two with a marker file:

1. Claude creates an empty file with a random name, e.g. `.wss-target-7f3k9q2m`, in its workspace folder.
2. Claude calls `copy_file` with `destination_marker: ".wss-target-7f3k9q2m"`.
3. The server searches the user profile and OneDrive folders for the marker. It skips `AppData`, hidden
   folders and links, and caches the result per session. The files are copied next to the marker.

Alternatively, pass `destination` as a Windows path, or set the **Download folder** plugin option.
Copies never overwrite existing files unless `overwrite: true`; a numbered copy is created instead.
Copies never go to UNC paths or network drives, and each file has a size limit (`WSS_MAX_COPY_MB`, default 500).

## Configuration

Plugin options (Cowork: plugin settings; Claude Code: `claude plugin configure windows-server-search`).
All options are optional.

| Option | Env variable | Default | Meaning |
|---|---|---|---|
| Additional servers / shares | `WSS_SERVERS` | – | `;`-separated UNC paths, e.g. `\\fs01\projects;\\fs02`. A bare server searches all its shares (via `net view`) |
| Use mapped network drives | `WSS_AUTO_DISCOVER` | `true` | Auto-discover servers from mapped drives (CIM `Win32_LogicalDisk`, `HKCU\Network`, PSDrives) |
| Exclude servers / shares | `WSS_EXCLUDE` | – | `;`-separated server names or UNC shares to ignore |
| Default maximum results | `WSS_MAX_RESULTS` | `50` | 1–500 |
| Download folder | `WSS_DOWNLOAD_DIR` | `%USERPROFILE%\Downloads\Windows Server Search` | Default destination for `copy_file` |
| – | `WSS_MAX_COPY_MB` | `500` | Maximum size per copied file |
| – | `WSS_QUERY_TIMEOUT` | `30` | Seconds per index query |
| – | `WSS_USE_NETBIOS` | `true` | Query FQDN hosts by their NetBIOS name, which Windows Search requires |
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
scripts/release.sh    # build, tag v$(cat VERSION), GitHub release, publish into the marketplace repo
```

To release: bump `VERSION`, commit, run `scripts/release.sh`. It needs `gh` with push access to both repos.
Pushing a `v*` tag also runs the CI `release` job. That job publishes to the marketplace when the
`MARKETPLACE_TOKEN` secret holds a token with write access to the marketplace repo.

## License

MIT
