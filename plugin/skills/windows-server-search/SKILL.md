---
name: windows-server-search
description: Find and read documents on the company's Windows file servers / network drives (e.g. Z:\, \\fileserver\share) using the server's Windows Search index. Use when the user asks to find, locate or look up files, documents, spreadsheets or presentations on a network drive, file share, file server or "the S: drive", or wants to know what a shared document says.
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

Always show the user the **drive path** (e.g. `Z:\Projects\Plan.docx`) when available, otherwise the UNC path,
so they can open the file themselves.

## Troubleshooting

- *No servers found*: no network drive is mapped. Ask the user to map one (`net use Z: \\server\share`)
  or set "Additional servers / shares" in the plugin settings.
- *Index errors* (`0x80040E37`, RPC errors, "table does not exist"): the file server must run the
  **Windows Search Service** (Windows Server feature "Windows Search Service") and index the shared folder.
  An administrator has to enable this on the server; the plugin cannot. `read_file` / `list_directory`
  still work without an index.
- Results only contain files the current Windows user is allowed to read.
