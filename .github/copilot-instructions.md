# Copilot Instructions

## Project Context

**ig-image-downloader** — A Flutter mobile app (Android / iOS) for downloading Instagram
content (photos, videos, Reels, IGTV, multi-image carousel posts). The user shares an
Instagram URL from the Instagram app; the app shows a preview selection screen, then
downloads chosen items to a persistent dated folder **and** the device gallery.

> Full architecture diagrams and flow charts: **[docs/architecture.md](../docs/architecture.md)**

**Tech stack:**
- Flutter (Dart) — mobile-first (Android / iOS); FVM 4.0.0 pinned to `stable`
- `Dio` — HTTP download engine (HTML scraping of og:video / og:image meta tags)
- `receive_sharing_intent` — Android ACTION_SEND / iOS share extension
- `gal` — saves files to Android MediaStore / iOS Photos
- `open_filex` — opens the saved file from within the app
- `path_provider` — resolves platform-appropriate base directories
- No database — all state is ephemeral (Riverpod in-memory)
- File output: `Downloads/IG Downloader/YYYY-MM-DD/` (Android), `Documents/IG Downloader/YYYY-MM-DD/` (iOS)

**Key conventions:**
- All Instagram URL parsing is in `lib/services/ig_url_parser.dart`
- Media extraction: fetch Instagram page HTML, parse `og:video` + `og:image` meta tags
- Download jobs are plain Dart models (`DownloadJob`) with status: pending / downloading / done / error
- `DownloadJob.outputPath` holds the permanent file path set on completion
- UI state managed with Riverpod (`StateNotifier`, `FutureProvider.family`)
- No global mutable singletons — pass providers / notifiers explicitly
- Run Flutter via FVM: `fvm flutter <command>` (binary at `~/.nix-profile/bin/fvm`)

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
