# Paddock internals

How the app is put together, how to run the live test suites, and the reasons behind the parts that look
odd. The user-facing guide is the [README](../README.md).

## How it works

- `TerminalHost` owns the single `TerminalController` (one libghostty app) and loads your Ghostty config,
  resolving a conditional `theme = dark:…,light:…` line first (see Troubleshooting).
- Each tab lazily gets a `TerminalPaneViewController` whose terminal view runs `herdr --session <name>`.
  Hidden panes keep their surface and herdr client; switching tabs only toggles visibility.
- Each tab also gets a `WorkspaceStore`, which owns one session's spaces (herdr workspaces) and the
  connection that keeps them current. It pings, subscribes to events, takes a `session.snapshot`, then
  refetches that snapshot whenever an event says something moved, reconnecting for ever on a 0.5 → 5 s
  backoff. A pane surface attaching (herdr starting up) cuts the wait short. Stores outlive tab switches.
  The tile indicator is the store's consumer, one slot per tile with precedence blocked > done > working:
  a red badge with a white count of spaces whose agent is waiting for input ("9+" above nine), else a green
  dot with a check when something is done and unseen, else a blue dot while anything is working, else
  nothing. A tile whose connection is not live is dimmed with the connection state as its tooltip; a live
  tile's tooltip is the session name. The VoiceOver label carries all three counts. Every tab opens its
  connection at launch (the selected tab at once, the rest once `herdr session list` has resolved socket
  paths), so indicators appear on unvisited tabs too.
- **Events are signals, not state.** herdr replays an unmarked historical backlog after every subscribe,
  one event per 100 ms, nine seconds of it on a long-lived session, and nothing in the protocol separates a
  replayed event from a live one, so their stale payloads must never be applied. `session.snapshot` is the
  only source of state; an event just asks for a fresh one, leading-edge debounced and floored at one every
  250 ms.
- The socket API is herdr's per-session Unix socket, newline-delimited JSON, **one request per connection**:
  every RPC opens a connection of its own and the events subscription keeps one for its lifetime. Reads run
  on a dedicated thread per connection publishing an `AsyncThrowingStream`. `FileHandle.bytes` cannot be
  used here, because a single parked `AsyncBytes` reader starves every other one in the process.
- Tabs are stored in `~/Library/Application Support/Paddock/tabs.json`, seeded from `herdr session list`
  on first launch. Removing a tab never touches the herdr session; "Stop Session…" does.
- When herdr detaches or exits, the pane shows an overlay with a Reattach button.
- The window uses the traditional Terminal-style arrangement: a standard title bar, no toolbar, and a
  regular fixed-width split item containing the 64 pt custom sidebar. The sidebar therefore has no
  authority over the window chrome. Its background is read from the controller's effective Ghostty
  configuration through `ghostty_config_get`, interpreted in the configured `window-colorspace`, then
  shifted slightly toward white for dark themes or black for light themes to separate it from the
  terminal. View ▸ Hide Sidebar (Ctrl+Cmd+S) remembers the choice.
- Window ▸ Enter Full Screen (Ctrl+Cmd+F) goes directly through `NSWindow.toggleFullScreen(_:)`. AppKit
  owns the separate Space, transition, safe area, top-edge title-bar reveal and traffic lights. With no
  toolbar installed, the reveal contains only the compact system title bar.
- No app-level Command shortcuts beyond the sidebar toggle and the standard application menu: herdr
  receives Command chords through the kitty keyboard protocol and owns them.

## App icon

The icon is an Icon Composer package, `Paddock/Resources/AppIcon.icon`: a solid paddock green (`#397844`)
fill and one vector layer, `Assets/mark.svg`, the cream Australian Shepherd with the fence arch and the
herd. Xcode 26 compiles it into every appearance (light, dark, tinted) and also writes the flattened
`AppIcon.icns` that macOS 14 and 15 use, so there is no hand-maintained `AppIcon.appiconset`; adding one
under the same name would be ignored. Edit the artwork in Icon Composer, or replace `mark.svg` directly.

Launch Services caches an app's icon by bundle path and modification time, and an incremental
`xcodebuild` does not touch the bundle directory's timestamp, so the Dock can keep showing a stale icon
after a rebuild. `touch` the `.app`, then `killall Dock`.

## Tests

Every suite is [Swift Testing](https://developer.apple.com/documentation/testing) (`import Testing`,
`@Test`, `#expect`); `xcodebuild` still runs the bundle and still writes an `.xctestrun`.

`make test` never touches a socket. The suites that need a running herdr (`HerdrSocketClientLiveTests`,
`WorkspaceStoreLiveTests`, `WorkspaceStoreHardeningLiveTests`) disable themselves with `.enabled(if:)`
unless `PADDOCK_LIVE_HERDR=1` is in the *test runner's* environment, which the scheme cannot set per
invocation. Inject it into the generated `.xctestrun` instead:

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
session (`paddock-qa-<random>`, started headlessly with `herdr --session <name> server` and deleted
afterwards), which `PADDOCK_LIVE_HERDR_SOCKET` and `PADDOCK_LIVE_HERDR_QA_SESSION` override. The
hardening suite refuses to run against a session that already exists, so an override cannot point it at
one of yours.

## Troubleshooting

**A pane runs a plain login shell instead of `herdr --session <name>`.** A ghostty config that uses the
conditional `theme = dark:A,light:B` syntax costs every pane its command. `Surface.init` re-derives a
surface's config whenever the surface's conditional state differs from the state the config was loaded with
(ghostty 1.3.1 `src/Surface.zig:468-484`), and that re-derivation replays the config file from scratch
(`src/config/Config.zig:4325-4338`). Only `working-directory` is copied back across the rebuild, so
everything the embedded apprt set for that one surface (`command`, `env`, `wait-after-command`) is dropped
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
