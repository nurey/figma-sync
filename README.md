# figma-sync

## What it does

Mirrors every visible top-level frame of a Figma file (including frames inside sections) to `<out>/<page>/<frame>__<node-id>.<format>`, calling the Figma REST API directly.
Re-runs export only frames whose content changed or that are new, move renamed ones, and delete the exported files of frames that were removed. State lives in `<out>/.figma-sync.json`.
If the file's version hasn't changed since the last complete run, it prints `Up to date (version …)` and exits without exporting anything.
Hidden frames and separator pages (pages named only with dashes or spaces) are skipped. So are frames Figma can't render (for example, empty ones): they are listed at the end of the run, and any earlier export of them is removed from the mirror.

## Prerequisites

- macOS or Linux.
- Ruby 3.3+, via rbenv or Homebrew: `ruby --version`. Only the standard library is used, so running it needs no gems (the tests use RSpec).
- A Figma personal access token. Generate one at <https://www.figma.com/settings> (Security → Personal access tokens → Generate new token), with the `File content: read` scope; the scopes are documented at <https://www.figma.com/developers/api#access-tokens>.

## Store the token

The script checks `--token` first, then `FIGMA_TOKEN`, then the macOS keychain item `figma-token`.

- **Keychain (recommended on macOS, one-time):** `-w` comes last with no value, so `security` prompts for the token and it never reaches your shell history.
  ```bash
  security add-generic-password -s figma-token -a "$USER" -U -w
  ```
  If you use 1Password, you can seed the keychain from it instead. Get the secret reference from the item's field menu (Copy secret reference):
  ```bash
  security add-generic-password -s figma-token -a "$USER" -U -w "$(op read '<secret reference>')"
  ```
- **Environment variable:** add this to your shell profile (`~/.zshrc`, `~/.bashrc`):
  ```bash
  export FIGMA_TOKEN="<token>"
  ```
- **Flag:** `figma-sync <file> --token "<token>"`. The token will show up in `ps` output and in your shell history, so use this only for one-off runs.

## Install

```bash
mkdir -p ~/bin && cp figma-sync ~/bin/ && chmod +x ~/bin/figma-sync
```

Add `~/bin` to your PATH if it isn't there already (for example, add `export PATH="$HOME/bin:$PATH"` to `~/.zshrc`).

## Usage

```bash
figma-sync <file-key-or-url> [--out DIR] [--scale N] [--format png|svg|jpg|pdf] [--force] [--dry-run] [--token TOKEN]
figma-sync -h
```

`--out` defaults to `~/Figma/<file name>/`, and `--scale` defaults to 2. Do a dry run first. It prints how many frames changed, are new or are unchanged, lists the frames it would export, the unchanged files it would rename and the stale files it would delete, and writes nothing. To tell what changed it does the same hashing pass as a real run (see below), so on a large file it takes minutes and downloads over a gigabyte:

```bash
figma-sync https://www.figma.com/design/<file-key>/... --dry-run
figma-sync <file-key>
```

`--force` re-exports everything even when the version hasn't changed. Changing `--scale` or `--format` also forces a full export.

## How changes are detected

Figma re-renders every frame after any edit to the file, which is slow (20–90 s per batch of 20 frames), so figma-sync only exports frames whose content changed:

- When the file's version changes, it fetches each frame's complete node tree, including vector path geometry, 20 frames per request to `/v1/files/<key>/nodes?geometry=paths`, and hashes it. That is about 8 s and 20–75 MB per request, or roughly 8 minutes and 2.5 GB for a 1,000-frame file. The whole-file endpoint can't be used: Figma rejects it as too large for big files.
- The hash is a SHA-256 of the frame's node tree as canonical JSON (keys sorted). Any change inside the frame, however deeply nested and including reshaped vector paths, changes it. The frame's own name is left out, so renaming a frame moves its file instead of exporting it again.
- A frame is exported if it is new, its hash differs from the one in the manifest, or its file is missing. Otherwise its file is kept, and moved if the frame or its page was renamed.
- If Figma refuses a hashing request or it times out, figma-sync splits it in halves, retrying only single frames. Frames it still can't hash get a warning and are exported, so one bad frame doesn't stop the sync. After three such failures in a run it stops hashing and exports the remaining frames without a hash. If Figma keeps rate limiting the hashing requests, the run stops with exit status 1 before changing anything, and the next run tries again.

The manifest (`"manifestVersion": 2`) stores `{"path": …, "hash": …}` for each frame. Older manifests that store only a path are upgraded in place: every frame is exported once on the next run, then compared by hash from then on.

Upgrade every copy of the script that syncs a folder at the same time. An older copy rejects a version 2 manifest as invalid, and this copy rejects a manifest from a newer version.

## Run it on a schedule (macOS launchd)

The `com.example.figma-sync.plist` template runs the script every hour from 9:00 to 17:00, Monday to Friday.

1. Copy it into place:
   ```bash
   cp com.example.figma-sync.plist ~/Library/LaunchAgents/
   ```
2. Open `~/Library/LaunchAgents/com.example.figma-sync.plist` in a text editor and replace:
   - every `YOUR_USER` with the output of `whoami`;
   - `YOUR_FILE_KEY` with the file key (the part after `/design/` in the Figma URL);
   - `YOUR_FOLDER` with the output folder's name. Keep `--out` explicit: without it, renaming the Figma file makes the next run export into a new folder, and the shared folder stops updating;
   - the first `ProgramArguments` entry with the output of `rbenv which ruby` (or `command -v ruby` if you don't use rbenv). This must be the real interpreter path. launchd doesn't load rbenv shims, and `/usr/bin/ruby` is too old.
3. Load it, run it once now, and check the log:
   ```bash
   launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.example.figma-sync.plist
   launchctl kickstart gui/$(id -u)/com.example.figma-sync
   tail ~/Library/Logs/figma-sync.log
   ```
   After you edit an already-loaded plist, run `launchctl bootout gui/$(id -u)/com.example.figma-sync` before `bootstrap`, otherwise the old definition stays loaded.
4. To disable it:
   ```bash
   launchctl bootout gui/$(id -u)/com.example.figma-sync
   ```

launchd jobs can't show a 1Password or biometric prompt, so create the keychain item (see "Store the token") before the first scheduled run.

The log file grows without limit. Clear it now and then with `: > ~/Library/Logs/figma-sync.log`.

## Troubleshooting

- **`HTTP 403`**: the token is invalid, expired, or lacks the `File content: read` scope. Store a new one with the keychain command above.
- **`HTTP 429`**: Figma is rate limiting you. This is retried automatically, waiting for the time in `Retry-After` (up to 120s) when Figma sends it, otherwise 5s, 15s and 45s. Server errors and network errors are retried the same way.
- **`No Figma token`**: none of `--token`, `FIGMA_TOKEN` or the keychain item gave a token. Under launchd, only the keychain item applies.
- **`contains whitespace, control or non-ASCII characters`**: the stored token has a stray newline, space or other character in it. Store it again.
- **Some frames failed**: they are listed at the end and the exit status is 1. The manifest's `version` is left unset, so the next run retries instead of reporting `Up to date`.

## Run the tests

```bash
bundle install && bundle exec rspec
```
