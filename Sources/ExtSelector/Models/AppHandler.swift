import AppKit

/// A concrete installed application that can open a file type or URL scheme.
///
/// Cheap to construct: the display name comes from `URLResourceValues`
/// (no `Info.plist` load), and `bundleID` is resolved lazily — only the app the
/// user actually applies needs it. Instances are deduplicated per URL by
/// `cached(_:)`, so the same app appearing across dozens of types is resolved
/// exactly once. The icon is loaded lazily and cached separately.
struct AppHandler: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String

    var id: URL { url }

    /// Use this (not `init`) everywhere — returns a shared, name-resolved
    /// instance per URL so the name lookup happens once per app, process-wide.
    static func cached(_ url: URL) -> AppHandler { registry.handler(for: url) }
    private static let registry = AppHandlerRegistry()

    private init(url: URL, name: String) {
        self.url = url
        self.name = name
    }

    /// Resolved on demand (only the app shown in a row needs it) and cached.
    var icon: NSImage { IconCache.shared.icon(for: url) }

    /// Bundle identifier, needed for the programmatic (silent) default-set API.
    /// Parses the bundle — called rarely (only on apply/reset/bulk), so kept lazy.
    var bundleID: String? { Bundle(url: url)?.bundleIdentifier }

    /// Display name via the file system's localized name — far cheaper than
    /// loading and parsing the app's `Info.plist`.
    fileprivate static func displayName(for url: URL) -> String {
        let raw = (try? url.resourceValues(forKeys: [.localizedNameKey]))?.localizedName
            ?? FileManager.default.displayName(atPath: url.path)
        return raw.hasSuffix(".app") ? String(raw.dropLast(4)) : raw
    }

    fileprivate static func build(_ url: URL) -> AppHandler {
        AppHandler(url: url, name: displayName(for: url))
    }

    static func == (lhs: AppHandler, rhs: AppHandler) -> Bool { lhs.url == rhs.url }
    func hash(into hasher: inout Hasher) { hasher.combine(url) }
}

/// Process-wide dedup cache for `AppHandler`. The same app is the candidate for
/// many types; resolving its name once and sharing the value avoids hundreds of
/// redundant lookups during warm-up and reverse indexing.
final class AppHandlerRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [URL: AppHandler] = [:]

    func handler(for url: URL) -> AppHandler {
        lock.lock(); defer { lock.unlock() }
        if let hit = cache[url] { return hit }
        let handler = AppHandler.build(url)
        cache[url] = handler
        return handler
    }
}

/// Small, bounded process-wide icon cache.
///
/// `NSWorkspace.icon(forFile:)` returns a multi-representation image up to
/// 512–1024px — megabytes each. We only ever draw icons at 16–18pt, so we
/// downscale to a small bitmap *before* caching. That turns ~1MB per icon into
/// a few KB, and a byte-budgeted `NSCache` caps the total.
final class IconCache: @unchecked Sendable {
    static let shared = IconCache()

    /// Display icons never exceed 18pt; 40px covers that crisply on 2× Retina.
    private static let side: CGFloat = 40

    private let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 128
        c.totalCostLimit = 8 * 1024 * 1024   // ~8MB ceiling for all icons
        return c
    }()

    func icon(for url: URL) -> NSImage {
        let key = url.path as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let small = Self.downscaled(NSWorkspace.shared.icon(forFile: url.path))
        let cost = Int(Self.side * Self.side * 4) * 4   // ~bytes incl. 2× backing
        cache.setObject(small, forKey: key, cost: cost)
        return small
    }

    /// Rasterize into a small fixed-size image, dropping the heavy original reps.
    private static func downscaled(_ image: NSImage) -> NSImage {
        let size = NSSize(width: side, height: side)
        let out = NSImage(size: size)
        out.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: size),
                   from: .zero, operation: .copy, fraction: 1)
        out.unlockFocus()
        return out
    }
}
