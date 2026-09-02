import Foundation
import GhosttyTerminal
import Testing

@testable import Paddock

@Suite("GhosttyConditionalTheme")
struct GhosttyConditionalThemeTests {
    @Test("an unconditional config is left alone")
    func unconditionalConfigIsUntouched() {
        #expect(GhosttyConditionalTheme.resolve("theme = Catppuccin Macchiato\n") == nil)
        #expect(GhosttyConditionalTheme.resolve("font-size = 14\n") == nil)
        #expect(GhosttyConditionalTheme.resolve("") == nil)
    }

    @Test("a conditional theme is lifted out of the config text")
    func conditionalThemeIsLifted() throws {
        let resolved = try #require(GhosttyConditionalTheme.resolve("""
        theme = "dark:Catppuccin Macchiato,light:Apple System Colors Light"
        font-size = 14
        """))

        #expect(!resolved.base.contains("theme"))
        #expect(resolved.base.contains("font-size = 14"))
        #expect(resolved.theme.dark.rendered == "theme = Catppuccin Macchiato")
        #expect(resolved.theme.light.rendered == "theme = Apple System Colors Light")
    }

    @Test("variant order and missing quotes do not matter")
    func variantOrderIsFree() throws {
        let resolved = try #require(
            GhosttyConditionalTheme.resolve("theme = light:Alabaster, dark:Afterglow")
        )
        #expect(resolved.theme.light.rendered == "theme = Alabaster")
        #expect(resolved.theme.dark.rendered == "theme = Afterglow")
    }

    @Test("a variant the config omits keeps libghostty's default")
    func omittedVariantStaysEmpty() throws {
        let resolved = try #require(GhosttyConditionalTheme.resolve("theme = dark:Afterglow"))
        #expect(resolved.theme.dark.rendered == "theme = Afterglow")
        #expect(resolved.theme.light.rendered.isEmpty)
    }

    @Test("the last theme line wins, as it does in ghostty")
    func lastThemeLineWins() throws {
        let resolved = try #require(GhosttyConditionalTheme.resolve("""
        theme = dark:First,light:FirstLight
        theme = dark:Second
        """))
        #expect(resolved.theme.dark.rendered == "theme = Second")
        // Untouched by the second line, which names no light variant.
        #expect(resolved.theme.light.rendered == "theme = FirstLight")
    }

    @Test("a commented-out theme is not a theme")
    func commentsAreIgnored() {
        #expect(GhosttyConditionalTheme.resolve("# theme = dark:X,light:Y\n") == nil)
    }

    @Test("a key that merely ends in theme is not the theme key")
    func onlyTheThemeKeyMatches() {
        #expect(GhosttyConditionalTheme.resolve("window-theme = dark:X,light:Y\n") == nil)
    }

    @Test("a later plain theme line cancels the lifted variants")
    func laterUnconditionalThemeWins() throws {
        let resolved = try #require(GhosttyConditionalTheme.resolve(
            "theme = dark:Afterglow,light:Alabaster\nfont-size = 14\ntheme = Catppuccin Macchiato\n"
        ))
        #expect(resolved.base.contains("theme = Catppuccin Macchiato"))
        #expect(!resolved.base.contains("dark:"))
        #expect(resolved.theme.light.rendered.isEmpty)
        #expect(resolved.theme.dark.rendered.isEmpty)
    }

    @Test("relative config-file includes are made absolute against the config directory")
    func relativeIncludesAreAbsolutized() throws {
        let directory = URL(fileURLWithPath: "/Users/me/.config/ghostty", isDirectory: true)
        let resolved = try #require(GhosttyConditionalTheme.resolve(
            "config-file = fonts\nconfig-file = ?local.conf\nconfig-file = /abs/keys\ntheme = dark:A,light:B\n",
            directory: directory
        ))
        #expect(resolved.base.contains("config-file = /Users/me/.config/ghostty/fonts"))
        #expect(resolved.base.contains("config-file = ?/Users/me/.config/ghostty/local.conf"))
        #expect(resolved.base.contains("config-file = /abs/keys"))
    }
}
