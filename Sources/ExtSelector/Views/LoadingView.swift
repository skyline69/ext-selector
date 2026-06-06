import SwiftUI
import AppKit

/// Launch splash: the standard macOS indeterminate spinner, centered on the
/// window background. Using the system `ProgressView` (an `NSProgressIndicator`
/// under the hood) gives the native look and free Reduce-Motion handling.
struct LoadingView: View {
    var body: some View {
        ZStack {
            Theme.windowBackground.ignoresSafeArea()

            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)   // true center
        }
    }
}

/// Configures the host window so content (and the splash) can fill the full
/// window, under the titlebar.
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configure(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { configure(nsView.window) }
    }

    private func configure(_ window: NSWindow?) {
        // Run once — reconfiguring the window on every render caused scroll hitches.
        guard let window, !window.styleMask.contains(.fullSizeContentView) else { return }
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        // Note: not movable-by-background — that would hijack the scrollbar drag
        // (and any other in-content drag). The titlebar still drags the window.
        window.isMovableByWindowBackground = false
    }
}
