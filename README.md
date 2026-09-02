# Paddock

A small AppKit shell around [libghostty-spm](https://github.com/Lakr233/libghostty-spm) that shows your
[herdr](https://herdr.dev) sessions as Slack-style side tabs. One tile per named herdr session
(`herdr --session <name>`), so personal and work agents live in different worlds.

## Requirements

- macOS 14+, Xcode 26, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- `herdr` on Homebrew's path (`brew install herdr`)

## One-time setup

libghostty ships without theme files. If your `~/.config/ghostty/config` names a theme, link Ghostty.app's
themes so the config loads unchanged:

```sh
ln -s /Applications/Ghostty.app/Contents/Resources/ghostty/themes ~/.config/ghostty/themes
```

## Build & run

```sh
make run      # xcodegen generate + xcodebuild + open the app
make test     # unit tests
```

## Spaces column

Next to the tile strip is a 220 pt column listing the *spaces* (herdr workspaces) of the selected session:
one row per space, `number · label`, with an 8 pt status dot — grey idle, blue working, orange blocked,
green done — and a pill on the space herdr currently has focused.

- **Clicking a row is a request, not a selection.** It sends `workspace.focus` over the session's socket and
  the pill only moves when herdr's `workspace_focused` event comes back, so a space changed inside the TUI
  and one changed from the column look identical. Keyboard focus stays in the terminal throughout.
- **The header's `+`** creates a space (`workspace.create`, focused straight away); a row's context menu
  renames or closes one.
- **The footer** carries the connection: "Connecting…", "Reconnecting… <reason>", or "Session not running"
  for a session that has not been started. Rows are never cleared on a failure — they stay, dimmed, as the
  last thing herdr said, and repopulate when it answers again.
- **View ▸ Hide Spaces** collapses the column on its own; hiding the tile strip hides both. Both choices are
  remembered.

Paddock's column and herdr's own sidebar show the same thing, so hide herdr's in `~/.config/herdr/config.toml`:

```toml
[ui]
sidebar_start_collapsed = true
sidebar_collapsed_mode = "hidden"
```

Then `herdr server reload-config` (or restart the session). herdr keeps its tab bar and splits *inside* a
space; only the space list moves out into Paddock.

## How it works

- `TerminalHost` owns the single `TerminalController` (one libghostty app) and loads your Ghostty config.
- Each tab lazily gets a `TerminalPaneViewController` whose `AppTerminalView` runs `herdr --session <name>`.
  Hidden panes keep their surface and herdr client; switching tabs only toggles visibility.
- Each visited tab also gets a `WorkspaceStore`, which owns one session's spaces list and the connection
  that keeps it current. It pings, subscribes to events, takes a `session.snapshot`, then reduces events
  until the stream ends, reconnecting for ever on a 0.5 → 5 s backoff. A pane surface attaching (herdr
  starting up) cuts the wait short. Stores outlive tab switches, so switching back is instant.
- The socket API is herdr's per-session Unix socket, newline-delimited JSON, **one request per connection**:
  every RPC opens a connection of its own and the events subscription keeps one for its lifetime. Reads run
  on a dedicated thread per connection publishing an `AsyncThrowingStream` — `FileHandle.bytes` cannot be
  used here, because a single parked `AsyncBytes` reader starves every other one in the process.
- Tabs are stored in `~/Library/Application Support/Paddock/tabs.json`, seeded from `herdr session list`
  on first launch. Removing a tab never touches the herdr session; "Stop Session…" does.
- When herdr detaches or exits, the pane shows an overlay with a Reattach button.
- View ▸ Hide Sidebar (Ctrl+Cmd+S) collapses the tile strip; the window then shows a regular title bar
  naming the active session. The choice is remembered.

## Tests

Every suite is [Swift Testing](https://developer.apple.com/documentation/testing) (`import Testing`,
`@Test`, `#expect`); `xcodebuild` still runs the bundle and still writes an `.xctestrun`.

`make test` never touches a socket. The suites that need a running herdr (`HerdrSocketClientLiveTests`,
`WorkspaceStoreLiveTests`, `WorkspaceStoreHardeningLiveTests`) disable themselves with `.enabled(if:)`
unless `PADDOCK_LIVE_HERDR=1` is in the *test runner's* environment, which the scheme cannot set per
invocation — inject it into the generated `.xctestrun` instead:

```sh
xcodebuild build-for-testing -scheme Paddock -configuration Debug -derivedDataPath DerivedData -quiet
# the format-1 xctestrun keys variables under the target's own node, not under TestConfigurations:
/usr/libexec/PlistBuddy -c \
    'Add :PaddockTests:EnvironmentVariables:PADDOCK_LIVE_HERDR string 1' \
    DerivedData/Build/Products/Paddock_macosx*.xctestrun
xcodebuild test-without-building -destination platform=macOS \
    -xctestrun DerivedData/Build/Products/Paddock_macosx*.xctestrun
```

They read `work` and `default` and only ever mutate a throwaway space (`paddock-e2e-*`) or a throwaway
session (`paddock-qa`, started headlessly with `herdr --session paddock-qa server`), which
`PADDOCK_LIVE_HERDR_SOCKET` and `PADDOCK_LIVE_HERDR_QA_SESSION` override.

## Troubleshooting

**A pane runs a plain login shell instead of `herdr --session <name>`.** The surface's command is handed to
libghostty as `ghostty_surface_config_s.command`, and the currently pinned libghostty-spm (1.5.2, ghostty
1.3.1) ignores that field: the child is always `/usr/bin/login -flp <user> /bin/bash --noprofile --norc -c
exec -l <your shell>`. `working_directory` from the same struct *is* applied, so this is specific to
`command`, and it happens identically whether the app is launched from Finder, `make run` or a shell — it is
not an inherited-environment problem. The Spaces column is unaffected, because it talks to herdr's daemon
socket rather than to the pane. Until the dependency gains the field back, run `herdr --session <name>` in
the pane by hand.

**`herdr` refuses to start inside a pane** (`HERDR_*` already set). Paddock launched from a herdr pane
inherits those markers and every surface's child would too, so `HerdrEnvironment.scrubInheritedMarkers()`
removes them from the process environment before the first surface spawns. Nothing to do.
