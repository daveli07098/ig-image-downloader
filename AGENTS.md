# Agent Instructions

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

## Session Wrap — Changelog Workflow

After any non-trivial session, run the session-wrap workflow:

1. Identify what was produced: source changes, configs, discoveries, or procedures.
2. Bump version and commit source changes together — one commit per logical change:
   ```bash
   ./scripts/bump-build.sh --no-commit
   git add <changed files> pubspec.yaml lib/screens/home_screen.dart
   git commit -m "type(scope): description"
   ```
3. Write `docs/<topic>.md` for reusable findings or procedures.
4. Append to `CHANGELOG.md` using dated session blocks:

```markdown
## [YYYY-MM-DD] — Session: <topic>
### Added / Fixed / Changed / Maintenance
- type(scope): what changed ([short-sha])
```

**Trigger phrases (run without asking):** "wrap up", "commit findings", "save and commit",
"update changelog", "log our changes", "commit the fix".

## Conventions

- Conventional Commits: `feat:`, `fix:`, `docs:`, `refactor:`, `chore:`
- One commit per logical change
- Keep a Changelog format for CHANGELOG.md
- `docs/` for reusable guides and architecture documentation

## Tool Restrictions

Minimal permissions — default deny, explicit allow.

Allowed by default:
- File read/write/search tools
- Terminal commands (flutter, dart, git — only when needed)
- Git operations

Require explicit user request:
- Browser / web tools
- MCP server tools
- Network / external API calls

## Safety Rules

- Never force-push without explicit confirmation
- Never delete files without confirmation
- Local commits first; push on explicit request only
