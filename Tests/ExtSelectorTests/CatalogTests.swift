import XCTest
import UniformTypeIdentifiers
@testable import ExtSelector

final class CatalogTests: XCTestCase {

    func testCatalogLoads() {
        XCTAssertFalse(Catalog.load().categories.isEmpty,
                       "Catalog.json failed to load or is empty")
    }

    /// Entries with an explicit `uti` are our own hand-written data — an
    /// undeclared/malformed one is a typo and must fail the build. (Entries that
    /// rely only on `ext` are environment-dependent: whether `.go` resolves
    /// depends on what apps are installed, so those are not asserted here.)
    func testExplicitUTIsAreValid() {
        let bad = Catalog.load().unresolvedEntries().filter { $0.entry.uti != nil }
        let report = bad
            .map { "\($0.category.name)/\($0.entry.name): \($0.reason)" }
            .joined(separator: "\n")
        XCTAssertTrue(bad.isEmpty, "Bad explicit UTIs (typos?):\n\(report)")
    }

    /// Scheme entries are hand-written data too: every one must resolve to a
    /// non-empty URL-scheme target (a blank/missing scheme is a typo).
    func testURLSchemeEntriesResolve() {
        let catalog = Catalog.load()
        let schemeEntries = catalog.categories
            .flatMap(\.types)
            .filter { $0.scheme != nil }
        XCTAssertFalse(schemeEntries.isEmpty, "Expected scheme entries (Web & Mail)")
        for entry in schemeEntries {
            guard case .resolved(.urlScheme(let scheme)) = entry.resolution else {
                return XCTFail("\(entry.name) did not resolve to a URL scheme")
            }
            XCTAssertFalse(scheme.isEmpty, "\(entry.name) has an empty scheme")
        }
    }

    /// Identifiers feed SwiftUI's diffing — duplicates cause UI glitches.
    func testIdentifiersAreUnique() {
        let catalog = Catalog.load()
        let categoryIDs = catalog.categories.map(\.id)
        XCTAssertEqual(categoryIDs.count, Set(categoryIDs).count, "Duplicate category ids")

        for category in catalog.categories {
            let typeIDs = category.types.map(\.id)
            XCTAssertEqual(typeIDs.count, Set(typeIDs).count,
                           "Duplicate type ids in \(category.name)")
        }
    }
}
