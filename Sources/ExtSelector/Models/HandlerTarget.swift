import UniformTypeIdentifiers

/// The thing a default-application assignment is *for*: either a document content
/// type (a UTI like `public.png`) or a URL scheme (`https`, `mailto`, …).
///
/// Generalizing over both lets one pipeline — catalog entry, `HandlerStore`
/// cache, and the Launch Services calls — serve file types and link/mail
/// handlers alike, instead of the file-type-only `UTType` the app started with.
enum HandlerTarget: Hashable, Sendable {
    case contentType(UTType)
    case urlScheme(String)

    /// Stable string used as the cache key (and handy in debug output).
    var key: String {
        switch self {
        case .contentType(let type): return "uti:" + type.identifier
        case .urlScheme(let scheme): return "scheme:" + scheme.lowercased()
        }
    }

    /// A representative URL for a scheme, used to query Launch Services via the
    /// modern `NSWorkspace` URL-based API. The path is irrelevant — only the
    /// scheme is consulted — so any well-formed URL works.
    var probeURL: URL? {
        switch self {
        case .contentType:
            return nil
        case .urlScheme(let scheme):
            let s = scheme.lowercased()
            // Hierarchical schemes need an authority to parse; the rest are opaque.
            switch s {
            case "http", "https", "ftp", "ftps", "webcal", "irc", "ircs":
                return URL(string: "\(s)://example.com")
            default:
                return URL(string: "\(s):example")
            }
        }
    }
}
