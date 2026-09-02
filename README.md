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

## How it works

- `TerminalHost` owns the single `TerminalController` (one libghostty app) and loads your Ghostty config.
- Each tab lazily gets a `TerminalPaneViewController` whose `AppTerminalView` runs `herdr --session <name>`.
  Hidden panes keep their surface and herdr client; switching tabs only toggles visibility.
- Tabs are stored in `~/Library/Application Support/Paddock/tabs.json`, seeded from `herdr session list`
  on first launch. Removing a tab never touches the herdr session; "Stop Session…" does.
- When herdr detaches or exits, the pane shows an overlay with a Reattach button.
- View ▸ Hide Sidebar (Ctrl+Cmd+S) collapses the tile strip; the window then shows a regular title bar
  naming the active session. The choice is remembered.
