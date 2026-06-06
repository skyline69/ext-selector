import AppKit
import CoreServices
import UniformTypeIdentifiers

/// Thin wrapper over the modern (macOS 12+) NSWorkspace default-handler API,
/// generalized over `HandlerTarget` so it drives both file types and URL
/// schemes. Not sandboxed — required to mutate system default handlers.
enum LaunchServicesManager {

    /// All installed apps able to handle the target, sorted by name.
    static func candidates(for target: HandlerTarget) -> [AppHandler] {
        let urls: [URL]
        switch target {
        case .contentType(let type):
            urls = NSWorkspace.shared.urlsForApplications(toOpen: type)
        case .urlScheme:
            urls = target.probeURL.map { NSWorkspace.shared.urlsForApplications(toOpen: $0) } ?? []
        }
        return urls
            .map(AppHandler.cached)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Current default app for the target, if any.
    static func currentDefault(for target: HandlerTarget) -> AppHandler? {
        switch target {
        case .contentType(let type):
            return NSWorkspace.shared.urlForApplication(toOpen: type).map(AppHandler.cached)
        case .urlScheme:
            return target.probeURL
                .flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) }
                .map(AppHandler.cached)
        }
    }

    /// Best guess at what the *system* would pick for a target, used to "reset" a
    /// user override. There is no public API to clear an override, so this is a
    /// heuristic: prefer a built-in Apple app (the usual original default —
    /// Preview for PDFs, Safari for http, Mail for mailto), otherwise the first
    /// candidate that isn't excluded.
    ///
    /// Pure — takes already-fetched candidates so callers reuse the cached
    /// `HandlerStore` snapshot instead of re-querying Launch Services. `excluding`
    /// lets reverse lookup steer *away* from a specific app even when it's the
    /// Apple default.
    static func suggestedHandler(candidates: [AppHandler],
                                 current: AppHandler?,
                                 excluding: AppHandler? = nil) -> AppHandler? {
        let pool = candidates.filter { $0 != excluding }
        if let apple = pool.first(where: { $0.bundleID?.hasPrefix("com.apple.") == true }) {
            return apple
        }
        return pool.first
    }

    /// Set the default app, triggering the system confirmation prompt. Throws on
    /// dynamic/unhandled types.
    static func setDefault(_ appURL: URL, for target: HandlerTarget) async throws {
        switch target {
        case .contentType(let type):
            try await NSWorkspace.shared.setDefaultApplication(at: appURL, toOpen: type)
        case .urlScheme(let scheme):
            try await NSWorkspace.shared.setDefaultApplication(at: appURL, toOpenURLsWithScheme: scheme)
        }
    }

    /// Set the default without the system confirmation prompt — used for bulk
    /// changes and resets where one prompt per item would be unusable. Uses the
    /// programmatic Launch Services API (the same one `duti` uses).
    @discardableResult
    static func setDefaultSilently(bundleID: String, for target: HandlerTarget) -> Bool {
        switch target {
        case .contentType(let type):
            return LSSetDefaultRoleHandlerForContentType(
                type.identifier as CFString, .all, bundleID as CFString
            ) == noErr
        case .urlScheme(let scheme):
            return LSSetDefaultHandlerForURLScheme(
                scheme as CFString, bundleID as CFString
            ) == noErr
        }
    }
}
