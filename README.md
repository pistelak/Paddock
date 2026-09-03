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
- **The tile badge.** A session tile carries the same dot in its corner when any of its spaces is working,
  blocked or done — the most urgent one wins — so a session you are not looking at can still ask for you.
  A tile gets its badge once it has been selected at least once, because that is when its socket opens.
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

- `TerminalHost` owns the single `TerminalController` (one libghostty app) and loads your Ghostty config,
  resolving a conditional `theme = dark:…,light:…` line first (see Troubleshooting).
- Each tab lazily gets a `TerminalPaneViewController` whose `AppTerminalView` runs `herdr --session <name>`.
  Hidden panes keep their surface and herdr client; switching tabs only toggles visibility.
- Each visited tab also gets a `WorkspaceStore`, which owns one session's spaces list and the connection
  that keeps it current. It pings, subscribes to events, takes a `session.snapshot`, then refetches that
  snapshot whenever an event says something moved, reconnecting for ever on a 0.5 → 5 s backoff. A pane
  surface attaching (herdr starting up) cuts the wait short. Stores outlive tab switches, so switching back
  is instant.
- **Events are signals, not state.** herdr replays an unmarked historical backlog after every subscribe —
  one event per 100 ms, nine seconds of it on a long-lived session — and nothing in the protocol separates a
  replayed event from a live one, so their stale payloads must never be applied. `session.snapshot` is the
  only source of rows; an event just asks for a fresh one, leading-edge debounced and floored at one every
  250 ms.
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

**A pane runs a plain login shell instead of `herdr --session <name>`.** A ghostty config that uses the
conditional `theme = dark:A,light:B` syntax costs every pane its command. `Surface.init` re-derives a
surface's config whenever the surface's conditional state differs from the state the config was loaded with
(ghostty 1.3.1 `src/Surface.zig:468-484`), and that re-derivation replays the config file from scratch
(`src/config/Config.zig:4325-4338`). Only `working-directory` is copied back across the rebuild, so
everything the embedded apprt set for that one surface — `command`, `env`, `wait-after-command` — is dropped
and ghostty falls back to the login shell; the giveaway in the log is `io_exec: shell integration
automatically injected shell=.zsh` where a herdr pane should say `shell could not be detected`. Nothing in
Paddock's Swift is involved, which is why `working_directory` appeared to work while `command` did not.

`GhosttyConditionalTheme` resolves such a line out of the config before libghostty sees it and hands the
light/dark pair to the package's `TerminalTheme` instead, which leaves the config unconditional. Appearance
switching still works, and rather better: the package re-renders and pushes the new config to surfaces that
already exist, which ghostty's own conditional does not do. Configs without a conditional theme are passed
to libghostty untouched. If a pane still shows a bare shell, check your config for any other conditional
value.

**`herdr` refuses to start inside a pane** (`HERDR_*` already set). Paddock launched from a herdr pane
inherits those markers and every surface's child would too, so `HerdrEnvironment.scrubInheritedMarkers()`
removes them from the process environment before the first surface spawns. Nothing to do.
