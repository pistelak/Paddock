import AppKit
import Testing

@testable import Paddock

@Suite("SidebarColor")
@MainActor
struct SidebarColorTests {
    private static let tolerance: CGFloat = 0.001

    @Test("a dark terminal background keeps its hue and lifts by 7 percent toward white")
    func darkBackground() throws {
        let terminal = NSColor(srgbRed: 0.14, green: 0.15, blue: 0.23, alpha: 1)
        let sidebar = try #require(SidebarViewController.sidebarColor(from: terminal).usingColorSpace(.sRGB))

        #expect(abs(sidebar.redComponent - (0.14 + 0.86 * 0.07)) < Self.tolerance)
        #expect(abs(sidebar.greenComponent - (0.15 + 0.85 * 0.07)) < Self.tolerance)
        #expect(abs(sidebar.blueComponent - (0.23 + 0.77 * 0.07)) < Self.tolerance)
        #expect(sidebar.blueComponent > sidebar.greenComponent)
        #expect(sidebar.greenComponent > sidebar.redComponent)
    }

    @Test("a light terminal background shades by 4 percent toward black")
    func lightBackground() throws {
        let terminal = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        let sidebar = try #require(SidebarViewController.sidebarColor(from: terminal).usingColorSpace(.sRGB))

        #expect(abs(sidebar.redComponent - 0.96) < Self.tolerance)
        #expect(abs(sidebar.greenComponent - 0.96) < Self.tolerance)
        #expect(abs(sidebar.blueComponent - 0.96) < Self.tolerance)
    }

    @Test("a Display P3 background outside the sRGB gamut is not clipped")
    func displayP3Background() throws {
        // Pure P3 green sits outside sRGB: its extended-sRGB red is negative.
        let terminal = NSColor(displayP3Red: 0, green: 1, blue: 0, alpha: 1)
        let sidebar = try #require(SidebarViewController.sidebarColor(from: terminal).usingColorSpace(.extendedSRGB))
        let reference = try #require(terminal.usingColorSpace(.extendedSRGB))

        #expect(reference.redComponent < 0)
        #expect(sidebar.redComponent < 0)
        // Light: every component moves 4 percent toward black.
        #expect(abs(sidebar.redComponent - reference.redComponent * 0.96) < Self.tolerance)
        #expect(abs(sidebar.greenComponent - reference.greenComponent * 0.96) < Self.tolerance)
        #expect(abs(sidebar.blueComponent - reference.blueComponent * 0.96) < Self.tolerance)
    }
}
