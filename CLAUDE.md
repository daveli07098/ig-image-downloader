# Claude Code Instructions

## Project Context

**ig-image-downloader** — A Flutter mobile app (Android / iOS) for downloading Instagram
content (photos, videos, Reels, IGTV, multi-image carousel posts). The user shares an
Instagram URL from the Instagram app; the app shows a preview selection screen, then
downloads chosen items to a persistent dated folder **and** the device gallery.

> Architecture diagrams and flow charts: **[docs/architecture.md](docs/architecture.md)**

**Tech stack:**
- Flutter (Dart) — mobile-first (Android / iOS); FVM 4.0.0 pinned to `stable`
- `Dio` — HTTP download engine (HTML scraping of og:video / og:image meta tags)
- `receive_sharing_intent` — Android ACTION_SEND / iOS share extension
- `gal` — saves files to Android MediaStore / iOS Photos
- `open_filex` — opens the saved file from within the app
- `path_provider` — resolves platform-appropriate base directories
- `connectivity_plus` — network type check (WiFi vs mobile data)
- `shared_preferences` — persists user settings (e.g. WiFi-only toggle)
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

Only use the minimum tools needed. Do not invoke browser, web-fetch, MCP server tools,
or external API calls unless the user explicitly asks.

Allowed by default:
- File read/write/search tools
- Terminal commands (flutter, dart, git — when needed)
- Git operations

Require explicit user request:
- Browser / web tools
- MCP server tools
- External API calls

## Git Conventions

- Conventional Commits: `feat:`, `fix:`, `docs:`, `refactor:`, `chore:`
- One logical change per commit
- Push only when user explicitly asks — never auto-push

## Auto-Commit Rule

**Commit immediately and automatically — without being asked — whenever:**
- A feature is fully implemented and works end-to-end
- A bug or build error is fixed and verified
- A refactor or cleanup is complete

```bash
# Bump version and stage it alongside code changes — one commit
./scripts/bump-build.sh --no-commit
git add <changed files> pubspec.yaml lib/screens/home_screen.dart
git commit -m "type(scope): description (vX.Y.Z.N)"
git rev-parse --short HEAD
```

> The version number is printed by `--no-commit` — include it at the end of the commit subject.

**Never:**
- Skip a commit because "more work is coming" — commit each logical unit as it finishes
- `git push` without explicit user request
- `git push --force` without confirmation

**Also run on:** "wrap up", "commit findings", "save and commit", "commit the fix".

## Session Wrap — Changelog Workflow

After any non-trivial session, run the session-wrap workflow:

1. Stage and commit all source changes with a conventional commit message.
2. Update `CHANGELOG.md` using dated session blocks:

```markdown
## [YYYY-MM-DD] — Session: <topic>
### Added / Fixed / Changed / Maintenance
- type(scope): what changed ([short-sha])
```

Create a new `## [YYYY-MM-DD]` block if today's date isn't already there.
Then amend the commit or make a separate `chore: update CHANGELOG` commit.

## Safety Rules

- Never `git push --force` without confirmation
- Never delete files without confirmation
- Local commits first; push only on explicit user request
