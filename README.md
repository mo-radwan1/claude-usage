# Claude Usage

A macOS menu-bar app that shows Claude Code usage at a glance.

The bar shows the 5-hour session, 7-day all-model, and model-specific weekly
limits (for example Fable). Click it for reset times, extra-usage credits, and
a manual refresh.

## Requirements

- macOS 14 or later
- Xcode Command Line Tools (`xcode-select --install`)
- [Claude Code](https://code.claude.com) installed and logged in (`claude login`)

Apple silicon and Intel both work. No Apple Developer account is required. The
app is ad-hoc signed for local use.

## Install

```sh
git clone https://github.com/mo-radwan1/claude-usage.git
cd claude-usage
chmod +x build.sh install.sh uninstall.sh
./install.sh
```

That builds the app, copies it to `~/Applications/Claude Usage.app`, and starts
it at login.

If macOS asks for Keychain access on first refresh, allow it. The app reads the
existing Claude Code credential. It does not prompt you to log in separately.

## Usage

The menu bar shows three percentages:

- `5h` current session
- `7d` current week, all models
- a one-letter label for a model-specific weekly limit when Claude reports one

Click the item for bars, reset times, extra-usage spend, and **Refresh Now**.
**Quit** stops the app until the next login, or until you run `./install.sh`
again.

Numbers turn orange at 70% and red at 90%. Extra-usage credits stay in the
panel, not the menu bar.

## Uninstall

```sh
./uninstall.sh
```

## How it works

The app calls Anthropic's account usage endpoint with the OAuth token Claude
Code already stores in Keychain. That endpoint is undocumented. It can change
or rate-limit aggressively.

Refresh behavior:

- every 15 minutes on success
- after the Mac wakes, unless a rate-limit backoff is still active
- sooner after a `429`, honoring `Retry-After` when present
- exponential backoff on other failures, capped at 15 minutes

If the access token is close to expiry, or a request returns `401`, the app
refreshes it and writes the rotated tokens back into the same Keychain item
Claude Code uses. Do not run two copies of this app, or another token-refreshing
tool, against the same login at the same time.

launchd restarts the process after a crash. Quit still exits normally.

Cached usage lives in `~/Library/Application Support/Claude Usage/usage.json`.
It contains percentages, amounts, and reset times. It never contains tokens.

## Rebuild

```sh
./build.sh
open "target/Claude Usage.app"
```

## License

MIT
