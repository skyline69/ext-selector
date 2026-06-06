import SwiftUI
import AppKit

@main
struct ExtSelectorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowResizability(.contentSize)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            // Replace the default "About ExtSelector" with a fuller panel:
            // adds a one-line description, credits, and copyright below the
            // name/version the standard panel already pulls from Info.plist.
            CommandGroup(replacing: .appInfo) {
                Button("About ExtSelector") { AboutPanel.show() }
            }
        }
    }
}

/// Builds the richer standard About panel. The system panel auto-fills the icon,
/// name, and version from the bundle; we add a description, credits link, and
/// copyright so the window isn't near-empty.
@MainActor
enum AboutPanel {
    static func show() {
        let credits = NSMutableAttributedString()
        let body = NSMutableParagraphStyle()
        body.alignment = .center
        body.lineSpacing = 2

        credits.append(NSAttributedString(
            string: "View and change the default app that opens each file type, browsable by category.\n\n",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: body
            ]))
        credits.append(NSAttributedString(
            string: "A native, dependency-free macOS app.\n\n",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: body
            ]))
        credits.append(NSAttributedString(
            string: "github.com/skyline69/ext-selector",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .link: URL(string: "https://github.com/skyline69/ext-selector")!,
                .paragraphStyle: body
            ]))

        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: credits,
            .init(rawValue: "Copyright"): "© 2026 Skyline. All rights reserved."
        ])
    }
}

/// A bare SPM executable launches as an accessory process: no Dock icon, window
/// may not focus. Force a regular, activated app.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        // No forced appearance — follow the system light/dark setting.
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
