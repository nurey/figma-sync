# figma-sync

## What it does

Mirrors every visible top-level frame of a Figma file (including frames inside sections) to `<out>/<page>/<frame>__<node-id>.<format>`, calling the Figma REST API directly.
Re-runs update changed frames, move renamed ones, and delete the exported files of frames that were removed. State lives in `<out>/.figma-sync.json`.
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

`--out` defaults to `~/Figma/<file name>/`, and `--scale` defaults to 2. Do a dry run first. It lists every frame with its target path, plus the stale files it would delete, and writes nothing:

```bash
figma-sync https://www.figma.com/design/<file-key>/... --dry-run
figma-sync <file-key>
```

`--force` re-exports everything even when the version hasn't changed. Changing `--scale` or `--format` also forces a full export.

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

## Share via Google Drive

In Drive for desktop, go to Preferences → My Mac → Add folder, and choose the output folder. Then share it from the Computers section on drive.google.com.

Don't point `--out` directly at `~/Library/CloudStorage/...`: macOS TCC blocks processes started by launchd from writing there.

## Troubleshooting

- **`HTTP 403`**: the token is invalid, expired, or lacks the `File content: read` scope. Store a new one with the keychain command above.
- **`HTTP 429`**: Figma is rate limiting you. This is retried automatically, waiting for the time in `Retry-After` (up to 120s) when Figma sends it, otherwise 5s, 15s and 45s. Server errors and network errors are retried the same way.
- **`No Figma token`**: none of `--token`, `FIGMA_TOKEN` or the keychain item gave a token. Under launchd, only the keychain item applies.
- **`contains whitespace or control characters`**: the stored token has a stray newline or space in it. Store it again.
- **Some frames failed**: they are listed at the end and the exit status is 1. The manifest's `version` is left unset, so the next run retries instead of reporting `Up to date`.

## Run the tests

```bash
bundle install && bundle exec rspec
```
