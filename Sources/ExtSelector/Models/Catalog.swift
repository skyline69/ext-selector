import Foundation
import UniformTypeIdentifiers

struct Catalog: Decodable {
    let categories: [Category]

    /// Loads the bundled catalog. Decode failure is a programmer error (the JSON
    /// ships in the bundle), so fail loud rather than silently showing nothing.
    static func load() -> Catalog {
        guard let url = Bundle.module.url(forResource: "Catalog", withExtension: "json") else {
            fatalError("Catalog.json missing from bundle")
        }
        do {
            let data = try Data(contentsOf: url)
            let catalog = try JSONDecoder().decode(Catalog.self, from: data)
            #if DEBUG
            catalog.warnAboutUnresolvedEntries()
            #endif
            return catalog
        } catch {
            fatalError("Catalog.json failed to decode: \(error)")
        }
    }

    /// Every entry that does not map to a declared system type, with the reason.
    func unresolvedEntries() -> [(category: Category, entry: FileTypeEntry, reason: String)] {
        categories.flatMap { category in
            category.types.compactMap { entry in
                if case .unresolved(let reason) = entry.resolution {
                    return (category, entry, reason)
                }
                return nil
            }
        }
    }

    private func warnAboutUnresolvedEntries() {
        for item in unresolvedEntries() {
            print("⚠️ Catalog: \(item.category.name)/\(item.entry.name): \(item.reason)")
        }
    }
}

struct Category: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let sfSymbol: String
    let types: [FileTypeEntry]
}

struct FileTypeEntry: Decodable, Identifiable, Hashable, Sendable {
    let name: String
    let ext: String?
    let uti: String?
    /// A URL scheme (`https`, `mailto`, …). Present instead of `ext`/`uti` for
    /// entries in the "Web & Mail" category — they manage link/mail handlers
    /// rather than document types.
    let scheme: String?

    var id: String { (uti ?? "") + "|" + (ext ?? "") + "|" + (scheme ?? "") + "|" + name }

    /// The short monospaced badge shown in the row: `.png` for a file type,
    /// `https` for a URL scheme. Nil when the entry has neither.
    var badge: String? {
        if let ext { return "." + ext }
        if let scheme { return scheme }
        return nil
    }

    /// The outcome of mapping this entry to a concrete handler target.
    enum Resolution: Hashable {
        case resolved(HandlerTarget)
        case unresolved(reason: String)
    }

    /// Resolve once, with a reason on failure. A `scheme` wins (it's always a
    /// valid target). Otherwise prefer an explicit UTI, then the filename
    /// extension. A content type is only accepted if it is `isDeclared` (some
    /// installed app/system actually declares it) — this catches typos like
    /// `public.jsonx` or extensions nothing handles.
    var resolution: Resolution {
        if let scheme, !scheme.isEmpty {
            return .resolved(.urlScheme(scheme.lowercased()))
        }
        if let uti {
            guard let type = UTType(uti) else {
                return .unresolved(reason: "Malformed UTI '\(uti)'")
            }
            guard type.isDeclared else {
                return .unresolved(reason: "Undeclared UTI '\(uti)'")
            }
            return .resolved(.contentType(type))
        }
        if let ext {
            guard let type = UTType(filenameExtension: ext), type.isDeclared else {
                return .unresolved(reason: "No declared type for '.\(ext)'")
            }
            return .resolved(.contentType(type))
        }
        return .unresolved(reason: "Entry declares no 'uti', 'ext', or 'scheme'")
    }

    var target: HandlerTarget? {
        if case .resolved(let target) = resolution { return target }
        return nil
    }
}
