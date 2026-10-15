---
name: windows-server-search
description: Find, read and copy documents on the company's Windows file servers / network drives (e.g. Z:\, \\fileserver\share) using the server's Windows Search index. Use when the user asks to find, locate or look up files, documents, spreadsheets, PDFs or presentations on a network drive, file share, file server or "the S: drive", wants to know what a shared document says, or wants such a file in the workspace.
---

# Searching Windows file servers

The `windows-server-search` MCP server queries the **Windows Search index of the file server itself**
(remote index query), so searches over large shares are fast and include file contents.

## Workflow

1. **`list_servers`** – see which servers/shares are available. Servers are auto-discovered from the
   network drives mapped on this PC (drive letters are shown), plus any configured in the plugin
   options. Use `check: true` if searches fail, to test whether each server's index is reachable.
2. **`search_files`** – search. Tips:
   - Words are ANDed and prefix-matched: `budget 2024` finds "Budget_2024_final.xlsx".
   - `"exact phrase"`, `-exclude`, `term1 OR term2` are supported.
   - `match: "filename"` for name-only searches, `"contents"` for text/properties only.
   - Narrow with `path` (`Z:\Projects\Alpha` or `\\server\share\folder`), `extensions` (`["pdf","docx"]`),
     `kind` (`document`, `picture`, `email`, …), `author`, `modified_after` / `modified_before` (ISO dates).
   - A query is optional when filters are given (e.g. all `.pptx` modified this month, `sort: "modified"`).
3. **`read_file`** – read text of a result (plain text, csv, code, `.docx`, `.xlsx`, `.pptx`).
   Long files come in chunks; continue with `offset: next_offset`.
4. **`list_directory`** – browse a folder around a result.
5. **`copy_file`** – copy files from the server into your workspace when you need the real file:
   PDFs, images, legacy `.doc`/`.xls`, or anything you want to process with your own tools
   (e.g. analysing a large spreadsheet with code). In **Cowork**, the MCP server runs on Windows and
   does not know the Windows path of your workspace folder, so:
   1. create an empty marker file with a random name, e.g. `.wss-target-7f3k9q2m`, in your workspace
      folder (the folder connected to this session);
   2. call `copy_file` with `path` (or `paths`) and `destination_marker: ".wss-target-7f3k9q2m"`;
   3. the files appear next to the marker (use `subfolder` to keep things tidy); delete the marker when done.
   Outside Cowork, pass `destination` as a Windows folder path instead. Existing files are never
   overwritten unless `overwrite: true`; a numbered copy (`report (1).pdf`) is created instead.

6. **`save_file`** – available unless writing was disabled. Saves text you write (`content` + `name`)
   or files from your workspace (`source_marker` + `source_name(s)`) into a server folder (`destination`).
   - Only save when the user asked you to, and tell them the exact path you saved to.
   - Existing files are never replaced unless you pass `overwrite: true` (only if the user wants the file
     replaced); the old version is then kept as `<name>.claude-backup-<timestamp>`. Otherwise a numbered copy
     is created – mention the new name.
   - Blocked paths, `.claude-policy` files and programs/scripts (`.exe`, `.ps1`, …) can't be written.
   - If the tool is missing, writing was disabled by the user (`"write": { "enabled": false }` in
     `%APPDATA%\windows-server-search-mcp\config.json`) or by IT (Group Policy). Replacing existing files
     additionally needs `"allowOverwrite": true` in that file.

Always show the user the **drive path** (e.g. `Z:\Projects\Plan.docx`) when available, otherwise the UNC path,
so they can open the file themselves.

## Access policy

Some folders or files may be blocked by an access policy, set by IT in a `.claude-policy` file on the
share or through Group Policy, or by the user in the plugin settings. Blocked items never appear in results.

- When `search_files` or `list_directory` returns `hidden_by_policy` > 0, **tell the user how many results
  were hidden by the access policy**, e.g. "3 matching files were hidden by your organisation's access policy".
- When a tool says a path is *blocked by the access policy*, accept it. Don't try other paths, drive letters,
  short names or links to reach the same content, and don't ask the user to paste it unless they offer.
- `list_servers` shows the active rules (`access_policy`) when the user asks why something is not found.

## Troubleshooting

- *No servers found*: no network drive is mapped. Ask the user to map one (`net use Z: \\server\share`)
  or to add servers. In Cowork, plugin settings can't be edited in the app, so the user has to create
  `%APPDATA%\windows-server-search-mcp\config.json` on their PC, e.g.
  `{ "servers": ["\\\\fs01\\projects"] }`. Explain this; you cannot write that file yourself.
- *Index errors* (`0x80040E37`, RPC errors, "table does not exist"): the file server must run the
  **Windows Search Service** (Windows Server feature "Windows Search Service") and index the shared folder.
  An administrator has to enable this on the server; the plugin cannot. `read_file` / `list_directory`
  still work without an index.
- Results only contain files the current Windows user is allowed to read.
- `copy_file` only writes to local folders on this PC, never to a server share or network drive.
