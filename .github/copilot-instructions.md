# Copilot Instructions

## Project Context

**ig-image-downloader** — A cross-platform desktop application for downloading Instagram
content (photos, videos, Reels, Stories/限時動態, IGTV, multi-image posts) by pasting a URL.

**Tech stack:**
- Flutter (Dart) — desktop-first (macOS / Windows / Linux), with mobile path open later
- `yt-dlp` (system binary) — actual download engine invoked via `dart:io` Process
- No database — all state is ephemeral; downloaded files land on local disk
- File output: configurable local folder, organized `YYYY-MM-DD/` sub-dirs

**Key conventions:**
- All Instagram URL parsing is done in a dedicated `ig_url_parser.dart` service
- Download jobs are plain Dart models (`DownloadJob`) with status: pending / downloading / done / error
- UI state managed with Riverpod (StateNotifier / AsyncNotifier)
- No global mutable singletons — pass providers / notifiers explicitly

## Tool Restrictions

Allowed by default:
- `read_file`, `list_dir`, `grep_search`, `file_search`
- `replace_string_in_file`, `create_file`
- `run_in_terminal` (for `flutter`, `dart`, `yt-dlp` commands)
- `get_errors`

Never invoke without explicit user request:
- Browser / web-fetch tools
- MCP server tools
- External API calls

## Auto-Commit Rule

**Commit immediately and automatically — without being asked — whenever:**
- A feature is fully implemented and works end-to-end
- A bug or build error is fixed and verified
- A refactor or cleanup is complete

**How to commit:**
```bash
git add <changed files>
git commit -m "type(scope): description"
git rev-parse --short HEAD
```

**Do NOT:**
- Skip a commit because "more work is coming" — commit each logical unit as it finishes
- `git push` without explicit user request
- `git push --force` without confirmation

**Also run on:** "wrap up", "commit findings", "save and commit", "commit the fix".

## Changelog Format — Dated Session Blocks

```markdown
## [YYYY-MM-DD] — Session: <topic>
### Added / Fixed / Changed / Maintenance
- type(scope): what changed ([short-sha])
```

Create a new `## [YYYY-MM-DD]` block if today's date isn't already there.
Then amend or make a separate `chore: update CHANGELOG` commit.
