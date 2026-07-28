# DesktopBot

DesktopBot is a native macOS utility that keeps the Desktop tidy and makes
screenshots useful to coding agents.

It has four related jobs:

1. Quickly move temporary screenshots into a searchable review archive.
2. File other old, loose Desktop files by type.
3. Organize the direct contents of a staging folder into a stable five-bucket
   layout, including whole generated folders.
4. Provide separate local MCP servers for screenshots, organization, and machine-wide file
   discovery.

No cleanup command permanently deletes anything.

## What gets moved

Screenshots go to:

```text
~/Pictures/DesktopBot Review/YYYY/MM/importance/category/
```

Importance is classified independently of subject:

- `sensitive` — protected OCR signals such as credentials, recovery codes, or
  two-factor information;
- `important` — explicit action, deadline, decision, production, security, or
  incident signals;
- `useful` — coding, error, website, and substantial text references;
- `routine` — duplicates, mostly visual captures, and unclassified screenshots.

Archived captures are renamed to a searchable form such as:

```text
2026-07-28_091500-important-error-vite-dev-server-failed.png
```

The name combines capture time, importance, subject category, and up to four
safe OCR topic words. Sensitive captures never put OCR-derived text into the
filename. Both renaming and importance folders can be disabled with
`renameArchivedScreenshots` and `groupScreenshotsByImportance`.

Other old files go to:

```text
~/Documents/DesktopBot Filing/YYYY/MM/category/
```

The default screenshot policy is deliberately quick:

- code, error, website, and text-heavy captures: after 1 day;
- exact duplicate captures: immediately, while the newest copy stays;
- visual or otherwise unclassified captures: after 7 days;
- receipts, tickets, credentials, recovery codes, and travel documents: kept
  for manual review.

Protected captures stay indefinitely by default. Set
`protectedMaximumAgeDays` to move older matches into the recoverable screenshot
archive after a chosen review window; this still never deletes them.

Loose non-screenshot files become eligible after 30 days. DesktopBot sorts them
into documents, spreadsheets, presentations, archives, installers, code, data,
images, audio, video, fonts, links, or other. It skips folders, hidden files,
symlinks, and recently modified files.

Top-level Desktop folders remain untouched by default. They can be moved intact
into the dated filing archive—without recursively inspecting or reorganizing
their contents—with an explicit policy:

```json
"otherFiles": {
  "enabled": true,
  "minimumAgeDays": 7,
  "archiveDirectory": "~/Documents/DesktopBot Filing",
  "includeDirectories": true,
  "directoryMinimumAgeDays": 3
}
```

iCloud placeholders that are not locally available are requested for download
and retried on the next run instead of being silently abandoned.

## Organize a cluttered staging folder

The reusable folder organizer defaults to `~/Desktop/Cleanup`. It looks only at
direct children and creates a predictable root:

```text
Cleanup/
├── Archive/
├── Documents/
├── Generated/
├── Images/
└── Screenshots/YYYY-MM/
```

It recognizes screenshot names, common document and media types, generated
visual/content hints, Desktop backup folders, and temporary/output directories.
Unknown files and folders are preserved in catch-all archive subfolders. Managed
destination folders, hidden files, and symbolic links are left alone.

Preview first:

```bash
.build/release/desktopbot organize ~/Desktop/Cleanup
```

Apply the displayed plan:

```bash
.build/release/desktopbot organize ~/Desktop/Cleanup --apply
```

Moves are top-level only. DesktopBot never recursively reorganizes a folder,
merges directories, deletes files, or overwrites a collision; it chooses a
numbered destination during preview and refuses if that destination changes.
Use `--files-only` if child directories should stay at the root.

The configured staging folders also run as part of the normal daily `run`
command. Change or disable that behavior in `~/.config/desktopbot/config.json`:

```json
"folderOrganization": {
  "enabled": true,
  "directories": ["~/Desktop/Cleanup"],
  "moveDirectories": true
}
```

## Quick start

Requires macOS 13 or newer and Xcode Command Line Tools.

```bash
swift test
swift build -c release
.build/release/desktopbot scan
```

`scan` is always a dry run and reports every proposed move. Apply it only after
the decisions look right:

```bash
.build/release/desktopbot run --apply
```

Create or replace the editable configuration:

```bash
.build/release/desktopbot init
open ~/.config/desktopbot/config.json
```

If an older config already exists and you want the new faster defaults, use
`desktopbot init --force` after saving any custom keywords.

## Run every day

```bash
.build/release/desktopbot install --hour 9 --minute 0
```

This copies the release binary to `~/.local/bin/desktopbot`, creates the config
if needed, and installs a user LaunchAgent that runs the move-only cleanup daily.

```bash
~/.local/bin/desktopbot status
~/.local/bin/desktopbot uninstall
```

Uninstalling the schedule leaves the binary, config, logs, and archives intact.

Applied runs are recorded in:

```text
~/Library/Logs/DesktopBot/audit.jsonl
~/Library/Logs/DesktopBot/other-files-audit.jsonl
~/Library/Logs/DesktopBot/folder-organizer-audit.jsonl
```

## Screenshot MCP

The `desktop-screenshots` MCP is for workflows like:

- “Look at my latest screenshot and fix that error.”
- “Compare this with my previous screenshot.”
- “Find the screenshot where I had the CORS problem.”
- “Archive that screenshot now.”

It exposes:

- `screenshot_latest` — returns the newest capture as an image and local OCR;
- `screenshot_list` — lists Desktop and archived captures;
- `screenshot_search` — searches filenames and the local OCR catalog;
- `screenshot_get` — returns a selected image and OCR;
- `screenshot_archive` — moves one Desktop capture into the review archive.

List and search results include `importance`; `screenshot_list` can filter by
`sensitive`, `important`, `useful`, or `routine`.

The OCR catalog is stored locally at:

```text
~/Library/Application Support/DesktopBot/catalog.json
```

Pre-indexing is optional because MCP searches update the catalog lazily:

```bash
~/.local/bin/desktopbot index
```

OCR runs locally with Apple Vision. When an MCP tool returns an actual screenshot,
the MCP host will provide that image to Codex or Claude as part of the conversation.

## Machine-files MCP

`machine-files` is intentionally a separate MCP connection. It searches the
existing macOS Spotlight index inside your home folder and returns file paths and
metadata. It does not return arbitrary file contents or change files.

It exposes:

- `file_search` — searches filenames, metadata, and Spotlight-indexed document
  contents;
- `file_info` — describes up to 20 exact paths;
- `file_inventory` — returns compact indexed-item counts for common home folders;
- `file_excerpt` — locally extracts only a bounded, query-centered passage from
  text, source, PDF, RTF, HTML, Word, or OpenDocument files.

`~/Library` and dot-directories are excluded from search by default. Bounded text
extraction from those locations is denied unless the narrower location is itself
an explicit root. The MCP refuses scopes outside allow-listed roots. Its intended
token-saving workflow is:

1. `file_search` returns at most a small list of metadata records.
2. `file_excerpt` returns up to three passages around the search phrase, with a
   4,000-character default budget.
3. The agent reads the whole file with its normal filesystem tools only if those
   passages are insufficient.

Keeping this separate from screenshots means you can enable the convenient,
narrow screenshot integration without also granting machine-wide discovery.

## Folder-organizer MCP

`desktop-organizer` is separate from the read-only machine-files server. It is
restricted to exact paths in `folderOrganization.directories` and exposes:

- `folder_organize_preview` — returns every proposed move without changing files,
  plus a one-time confirmation token;
- `folder_organize_apply` — applies only that reviewed in-memory plan.

The apply tool is advertised as state-changing/destructive to MCP hosts so their
normal approval UI can intervene. The implementation still performs move-only
operations, refuses overwrites, and writes an audit record.

### Mounted and synced remote shares

In the full config generated by `desktopbot init`, update the existing
`machineFiles` value to add mounted SMB/NFS shares, synced cloud folders, or
`rclone` mounts:

```json
"machineFiles": {
  "allowedRoots": [
    "~",
    "/Volumes/Team Share",
    "~/Library/CloudStorage/Dropbox"
  ],
  "priorityDirectories": [
    "~/dev"
  ],
  "allowTextExcerpts": true,
  "maximumExcerptCharacters": 12000
}
```

Priority directories are searched before broad roots and receive a strong
ranking boost. `~/dev` is the default, so repository matches naturally appear
ahead of similarly named files elsewhere. Because Spotlight often skips source
trees, DesktopBot also uses an installed `rg`/ripgrep binary for bounded local
content matching inside priority directories while still returning paths only.

Spotlight content search works when macOS indexes the mounted volume. For a
non-indexed remote root, filename-only mode falls back to a bounded directory
walk. A future optional local full-text index would be the right extension for
content-searching large shares that Spotlight cannot index; the current version
does not silently copy a remote share into its own database.

## Connect Codex and Claude Code

Print the current setup commands:

```bash
~/.local/bin/desktopbot mcp-config
```

Or add them directly:

```bash
codex mcp add desktop-screenshots -- ~/.local/bin/desktopbot mcp
codex mcp add machine-files -- ~/.local/bin/desktopbot files-mcp
codex mcp add desktop-organizer -- ~/.local/bin/desktopbot organizer-mcp

claude mcp add --scope user --transport stdio desktop-screenshots -- \
  ~/.local/bin/desktopbot mcp
claude mcp add --scope user --transport stdio machine-files -- \
  ~/.local/bin/desktopbot files-mcp
claude mcp add --scope user --transport stdio desktop-organizer -- \
  ~/.local/bin/desktopbot organizer-mcp
```

Choose only the server or host you want. Restart Codex or Claude Code after
changing MCP configuration, then inspect connections with `/mcp`.

The MCP servers use newline-delimited JSON-RPC over stdio and advertise tool
safety annotations. Screenshot discovery tools and every machine-files tool are
read-only. `screenshot_archive` and the confirmed organizer apply tool change
state only by moving files within configured locations.

## macOS privacy permission

Desktop, Documents, and Pictures are protected folders on recent macOS versions.
If a daily or MCP run reports `Operation not permitted`, grant Full Disk Access
to `~/.local/bin/desktopbot` in **System Settings → Privacy & Security → Full
Disk Access**, then reload the daily job or restart the MCP host.

## Commands

```text
desktopbot scan [--config PATH] [--json]
desktopbot run [--apply] [--config PATH] [--json] [--quiet]
desktopbot init [--force]
desktopbot install [--hour 9] [--minute 0]
desktopbot status
desktopbot uninstall
desktopbot index [--config PATH]
desktopbot organize [PATH] [--apply] [--files-only] [--json]
desktopbot mcp [--config PATH]
desktopbot files-mcp [--config PATH]
desktopbot organizer-mcp [--config PATH]
desktopbot mcp-config
```

## Why move instead of delete?

OCR and extension-based classification are useful evidence, not guarantees.
Moving candidates into dated folders clears the Desktop while preserving a simple
recovery path. Permanent retention or Trash rules can be added later, after the
policy has proved itself on real files.

## Privacy and security

- OCR uses Apple Vision locally; screenshots are not uploaded by DesktopBot.
- Machine search returns bounded metadata/excerpts only from configured roots.
- The organizer MCP cannot accept arbitrary machine paths.
- Local config, build output, Finder metadata, and `DesktopBot.local.json` are
  ignored by version control.
- There is no telemetry or network client in the package.

## License

MIT
