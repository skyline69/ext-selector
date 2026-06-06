import SwiftUI
import AppKit

struct ContentView: View {
    private let catalog = Catalog.load()
    @State private var selected = 0
    @State private var refreshToken = 0
    @State private var isLoading = true
    @State private var searchText = ""
    @State private var bulkData: BulkData?
    /// Reverse index: each installed app that is the current default for one or
    /// more catalog types, with those types. Drives "what opens with X?" search.
    /// Built lazily on the first reverse query and cleared when search clears, so
    /// it costs nothing for users who never use reverse lookup.
    @State private var appIndex: [AppDefaults] = []
    @State private var indexBuilt = false
    @State private var indexBuilding = false
    /// Pending bulk operations awaiting confirmation (count shown to the user).
    @State private var pendingResetAll: PendingResetAll?
    /// Stack of reversible bulk operations; most recent undone first (⌘Z).
    @State private var undoStack: [UndoOp] = []
    /// Appearance override: "system" (follow OS), "light", or "dark". Persisted.
    @AppStorage("appearancePreference") private var appearancePref = "system"
    @State private var showSettings = false

    private var category: Category? {
        catalog.categories.indices.contains(selected) ? catalog.categories[selected] : nil
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Apps whose name matches the current query (≥2 chars). Non-empty ⇒ the
    /// search flips to reverse mode: "what opens with this app?"
    private var reverseMatches: [AppDefaults] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard query.count >= 2 else { return [] }
        return appIndex.filter { $0.app.name.lowercased().contains(query) }
    }

    private var isReverse: Bool { !reverseMatches.isEmpty }

    /// What the list shows: the selected category, or flat search results.
    private var displayed: (title: String, entries: [FileTypeEntry]) {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else {
            return (category?.name ?? "", category?.types ?? [])
        }
        var seen = Set<String>()
        let matches = catalog.categories.flatMap(\.types).filter { entry in
            entry.name.lowercased().contains(query) || (entry.ext?.lowercased().contains(query) ?? false)
        }
        .filter { seen.insert($0.id).inserted }
        return ("Results", matches)
    }

    var body: some View {
        NavigationStack {
            content
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        CategoryNavBar(categories: catalog.categories, selected: $selected)
                    }
                    ToolbarItem(placement: .primaryAction) {
                        settingsMenu
                    }
                }
                .toolbar(isLoading ? .hidden : .automatic, for: .windowToolbar)
        }
        .frame(width: Theme.windowWidth, height: Theme.windowHeight)
        .tint(Theme.accent)
        .background(WindowConfigurator())
        .onAppear(perform: applyAppearance)
        .onChange(of: appearancePref) { _, _ in applyAppearance() }
        .overlay {
            if isLoading {
                LoadingView()
                    .ignoresSafeArea()
                    .transition(.opacity)
            }
        }
        .task { await warmUp() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Defaults may have changed in another app while we were away —
            // drop the cache and force every visible row to re-read.
            refreshDefaults()
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            searchField
            if isReverse {
                reverseHeader
                Rectangle().fill(Theme.hairline).frame(height: 1)
                ReverseResultsView(matches: reverseMatches) { entry, app in
                    Task { await reset(entry, excluding: app) }
                }
            } else {
                header
                Rectangle().fill(Theme.hairline).frame(height: 1)
                if displayed.entries.isEmpty {
                    emptyState
                } else {
                    // Scroll state lives in this child so per-frame scroll updates
                    // don't re-render ContentView (and re-run WindowConfigurator).
                    CategoryScrollView(entries: displayed.entries,
                                       refreshToken: refreshToken,
                                       onDefaultsChanged: refreshIndexIfBuilt)
                }
            }

            footer
        }
        .background(Theme.windowBackground)
        .onChange(of: selected) { _, _ in searchText = "" }
        .onChange(of: searchText) { _, new in
            let query = new.trimmingCharacters(in: .whitespaces)
            if query.count >= 2 {
                if !indexBuilt && !indexBuilding { Task { await rebuildAppIndex() } }
            } else if indexBuilt {
                appIndex = []
                indexBuilt = false   // free it; rebuilds cheaply from cache next time
            }
        }
        .background(undoShortcut)   // ⌘Z works in any mode, even when no button is shown
        .alert("Reset All to System Defaults",
               isPresented: Binding(get: { pendingResetAll != nil },
                                    set: { if !$0 { pendingResetAll = nil } }),
               presenting: pendingResetAll) { pending in
            Button("Reset \(pending.count) Type\(pending.count == 1 ? "" : "s")", role: .destructive) {
                let p = pending; pendingResetAll = nil
                Task { await resetAll(p.category) }
            }
            Button("Cancel", role: .cancel) { pendingResetAll = nil }
        } message: { pending in
            Text("Reset \(pending.count) type\(pending.count == 1 ? "" : "s") in \(pending.category.name) to the app the system would pick?")
        }
    }

    /// Invisible button carrying the ⌘Z shortcut so undo works regardless of
    /// whether the header (and its visible Undo button) is on screen.
    private var undoShortcut: some View {
        Button("Undo") { Task { await undoLast() } }
            .keyboardShortcut("z", modifiers: .command)
            .disabled(undoStack.isEmpty)
            .opacity(0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// Header for reverse ("by app") search mode.
    private var reverseHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "app.dashed").font(.caption).foregroundStyle(Theme.accent)
            Text("Opens with")
                .font(.system(.headline, design: .rounded))
            Text("\(reverseMatches.count) app\(reverseMatches.count == 1 ? "" : "s")")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(.quaternary, in: Capsule())
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Search types…", text: $searchText)
                .textFieldStyle(.plain)
                .font(.subheadline)
            if isSearching {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .pointerStyle(.link)
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.surfaceStroke))
        .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 6)
    }

    /// Finder-style status bar pinned to the bottom — fills the space under short
    /// lists and reports what's on screen. Uses the system `.bar` material.
    private var footer: some View {
        Text(footerText)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .overlay(alignment: .top) {
                Rectangle().fill(Theme.hairline).frame(height: 1)
            }
            .background(.bar)
    }

    private var footerText: String {
        if isReverse {
            let n = reverseMatches.count
            return "\(n) app\(n == 1 ? "" : "s")"
        }
        let n = displayed.entries.count
        if isSearching { return "\(n) result\(n == 1 ? "" : "s")" }
        return "\(n) type\(n == 1 ? "" : "s")"
    }

    private var emptyState: some View {
        ContentUnavailableView(
            isSearching ? "No matches" : "Nothing here",
            systemImage: isSearching ? "magnifyingglass" : "square.grid.2x2"
        )
        .frame(maxHeight: .infinity)
    }

    /// Prefetch the first category's handlers (warms the cache so its rows pop in
    /// instantly), keep the splash up for a brief minimum, then fade it out.
    private func warmUp() async {
        let clock = ContinuousClock()
        let start = clock.now

        if let first = catalog.categories.first {
            // Warm the first category's handlers concurrently — snapshots compute
            // off the actor, so these run in parallel rather than one at a time.
            await withTaskGroup(of: Void.self) { group in
                for entry in first.types {
                    guard case .resolved(let target) = entry.resolution else { continue }
                    group.addTask { _ = await HandlerStore.shared.snapshot(for: target) }
                }
            }
        }

        let minimum = Duration.milliseconds(350)
        let elapsed = clock.now - start
        if elapsed < minimum {
            try? await Task.sleep(for: minimum - elapsed)
        }

        withAnimation(.smooth(duration: 0.5)) { isLoading = false }
        // Note: the reverse index is NOT built here — it's built lazily on the
        // first reverse search (see the searchText onChange), so launch stays fast.
    }

    /// Snapshot every resolved type (in parallel) and group by its current
    /// default app. Cheap after warm-up — `HandlerStore` caches every lookup.
    private func rebuildAppIndex() async {
        indexBuilding = true
        let entries = catalog.categories.flatMap(\.types)
        let pairs: [(FileTypeEntry, HandlerStore.Snapshot)] =
            await withTaskGroup(of: (FileTypeEntry, HandlerStore.Snapshot)?.self) { group in
                for entry in entries {
                    guard case .resolved(let target) = entry.resolution else { continue }
                    group.addTask { (entry, await HandlerStore.shared.snapshot(for: target)) }
                }
                var collected: [(FileTypeEntry, HandlerStore.Snapshot)] = []
                for await pair in group { if let pair { collected.append(pair) } }
                return collected
            }

        var groups: [URL: (app: AppHandler, entries: [FileTypeEntry])] = [:]
        for (entry, snapshot) in pairs {
            guard let current = snapshot.current else { continue }
            groups[current.url, default: (current, [])].entries.append(entry)
        }
        appIndex = groups.values
            .map { AppDefaults(app: $0.app, entries: $0.entries) }
            .sorted { $0.app.name.localizedCaseInsensitiveCompare($1.app.name) == .orderedAscending }
        indexBuilt = true
        indexBuilding = false
    }

    /// Apply the appearance preference app-wide via `NSApp.appearance`, which
    /// covers the main window *and* popovers consistently. `nil` follows the
    /// system — and crucially clears any previously-forced scheme (which
    /// `.preferredColorScheme(nil)` fails to do, leaving the window stale).
    private func applyAppearance() {
        switch appearancePref {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark":  NSApp.appearance = NSAppearance(named: .darkAqua)
        default:      NSApp.appearance = nil   // follow the system
        }
    }

    private var settingsMenu: some View {
        Button {
            showSettings.toggle()
        } label: {
            Image(systemName: "gearshape")
        }
        .pointerStyle(.link)
        .help("Settings")
        .popover(isPresented: $showSettings, arrowEdge: .bottom) {
            SettingsMenuView(
                appearance: $appearancePref,
                onAbout: { showSettings = false; showAbout() },
                onQuit: { NSApp.terminate(nil) }
            )
        }
    }

    private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "ExtSelector"
        ])
    }

    /// Drop the cache and re-read every visible default — the manual Refresh
    /// button, and the on-re-focus handler, both route through here.
    private func refreshDefaults() {
        Task {
            await HandlerStore.shared.invalidateAll()
            refreshToken += 1
            if indexBuilt { await rebuildAppIndex() }
        }
    }

    /// Rebuild the reverse index only if it currently exists (it's lazy).
    private func refreshIndexIfBuilt() {
        guard indexBuilt else { return }
        Task { await rebuildAppIndex() }
    }

    /// Reset one type to its system-suggested handler, steering away from
    /// `excluding` (the app the user is flipping types off of, in reverse mode).
    private func reset(_ entry: FileTypeEntry, excluding: AppHandler?) async {
        guard case .resolved(let target) = entry.resolution else { return }
        let snapshot = await HandlerStore.shared.snapshot(for: target)
        guard let suggested = LaunchServicesManager.suggestedHandler(
                candidates: snapshot.candidates, current: snapshot.current, excluding: excluding),
              suggested != excluding,
              let bundleID = suggested.bundleID else { return }
        LaunchServicesManager.setDefaultSilently(bundleID: bundleID, for: target)
        await HandlerStore.shared.invalidate(target)
        refreshToken += 1
        if indexBuilt { await rebuildAppIndex() }
    }

    /// Reset every type in a category to its system default (silent, no prompts).
    private func resetAll(_ category: Category) async {
        var changes: [UndoChange] = []
        for entry in category.types {
            guard case .resolved(let target) = entry.resolution else { continue }
            let snapshot = await HandlerStore.shared.snapshot(for: target)
            guard let suggested = LaunchServicesManager.suggestedHandler(
                    candidates: snapshot.candidates, current: snapshot.current),
                  suggested != snapshot.current,
                  let bundleID = suggested.bundleID else { continue }
            changes.append(UndoChange(target: target, previousBundleID: snapshot.current?.bundleID))
            LaunchServicesManager.setDefaultSilently(bundleID: bundleID, for: target)
        }
        pushUndo(changes)
        await HandlerStore.shared.invalidateAll()
        refreshToken += 1
        if indexBuilt { await rebuildAppIndex() }
    }

    /// Count how many types "Reset all" would actually change, then stage the
    /// confirmation. No prompt when the category is already all system defaults.
    /// Reuses cached snapshots — no redundant Launch Services queries.
    private func prepareResetAll(_ category: Category) async {
        var count = 0
        for entry in category.types {
            guard case .resolved(let target) = entry.resolution else { continue }
            let snapshot = await HandlerStore.shared.snapshot(for: target)
            if let suggested = LaunchServicesManager.suggestedHandler(
                    candidates: snapshot.candidates, current: snapshot.current),
               suggested != snapshot.current { count += 1 }
        }
        guard count > 0 else { return }
        pendingResetAll = PendingResetAll(category: category, count: count)
    }

    /// Push a reversible operation. Empty change sets aren't recorded.
    private func pushUndo(_ changes: [UndoChange]) {
        guard !changes.isEmpty else { return }
        undoStack.append(UndoOp(changes: changes))
    }

    /// Revert the most recent bulk operation by re-pointing each affected type
    /// to its previous handler. Types that had *no* prior default can't be
    /// restored to "none" (no public API) and are left as-is.
    private func undoLast() async {
        guard let op = undoStack.popLast() else { return }
        for change in op.changes {
            guard let bundleID = change.previousBundleID else { continue }
            LaunchServicesManager.setDefaultSilently(bundleID: bundleID, for: change.target)
        }
        await HandlerStore.shared.invalidateAll()
        refreshToken += 1
        if indexBuilt { await rebuildAppIndex() }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(displayed.title)
                .font(.system(.headline, design: .rounded))
            Text("\(displayed.entries.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(.quaternary, in: Capsule())
            Spacer()
            if !undoStack.isEmpty { undoButton }
            if !isSearching, let category {
                resetAllButton(for: category)
                bulkButton(for: category)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var undoButton: some View {
        Button {
            Task { await undoLast() }
        } label: {
            Image(systemName: "arrow.counterclockwise")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .help("Undo last bulk change (⌘Z)")
    }

    private func resetAllButton(for category: Category) -> some View {
        Button {
            Task { await prepareResetAll(category) }
        } label: {
            Image(systemName: "arrow.uturn.backward")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .help("Reset every type in this category to its system default")
    }

    private func bulkButton(for category: Category) -> some View {
        Button {
            // Load apps + per-type compatibility first, then present via
            // item-binding so the popover always gets a fully loaded snapshot.
            Task {
                if let data = await loadBulkData(for: category) { bulkData = data }
            }
        } label: {
            Label("Set all", systemImage: "square.stack.3d.up")
                .labelStyle(.iconOnly)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .help("Set one app for the types in this category it can open")
        .popover(item: $bulkData, arrowEdge: .bottom) { data in
            BulkAssignView(apps: data.apps, types: data.types) { app, targets in
                bulkData = nil
                Task { await bulkApply(app, to: targets) }
            }
        }
    }

    /// Gather everything the bulk popover needs in one cache-warm pass: the union
    /// of candidate apps (for the picker) and, per resolved type, which apps can
    /// open it and what its current default is (for the per-type compatibility
    /// checklist). Returns nil when the category has no apps or no resolved types.
    private func loadBulkData(for category: Category) async -> BulkData? {
        var seen = Set<URL>()
        var apps: [AppHandler] = []
        var types: [BulkTypeInfo] = []
        for entry in category.types {
            guard case .resolved(let target) = entry.resolution else { continue }
            let snapshot = await HandlerStore.shared.snapshot(for: target)
            var candidateURLs = Set<URL>()
            for app in snapshot.candidates {
                candidateURLs.insert(app.url)
                if seen.insert(app.url).inserted { apps.append(app) }
            }
            types.append(BulkTypeInfo(entry: entry, target: target,
                                      candidateURLs: candidateURLs,
                                      currentURL: snapshot.current?.url))
        }
        guard !apps.isEmpty, !types.isEmpty else { return nil }
        apps.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return BulkData(category: category, apps: apps, types: types)
    }

    /// Silently set `app` as the default for the given targets (the ones the user
    /// ticked in the checklist). Targets already on `app` are skipped as no-ops.
    private func bulkApply(_ app: AppHandler, to targets: [HandlerTarget]) async {
        guard let bundleID = app.bundleID else { return }
        var changes: [UndoChange] = []
        for target in targets {
            let snapshot = await HandlerStore.shared.snapshot(for: target)
            guard snapshot.current != app else { continue }
            changes.append(UndoChange(target: target, previousBundleID: snapshot.current?.bundleID))
            LaunchServicesManager.setDefaultSilently(bundleID: bundleID, for: target)
        }
        pushUndo(changes)
        await HandlerStore.shared.invalidateAll()
        refreshToken += 1
        if indexBuilt { await rebuildAppIndex() }
    }
}

/// Identifiable payload that drives the bulk-assign popover. `BulkTypeInfo` and
/// the popover view itself live in `BulkAssignView.swift`.
private struct BulkData: Identifiable {
    var id: String { category.id }
    let category: Category
    let apps: [AppHandler]
    let types: [BulkTypeInfo]
}

/// Staged "Reset all" awaiting confirmation.
private struct PendingResetAll: Identifiable {
    var id: String { category.id }
    let category: Category
    let count: Int
}

/// One handler change, with enough to reverse it.
private struct UndoChange {
    let target: HandlerTarget
    let previousBundleID: String?
}

/// A reversible bulk operation: the set of changes it made.
private struct UndoOp {
    let changes: [UndoChange]
}

/// The scrolling list for one category. Owns the scroll metrics/position so
/// per-frame scroll updates stay contained here and don't re-render the parent.
private struct CategoryScrollView: View {
    let entries: [FileTypeEntry]
    let refreshToken: Int
    var onDefaultsChanged: () -> Void = {}

    @State private var metrics = ScrollMetrics()
    @State private var position = ScrollPosition()

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { i, entry in
                    FileTypeRowView(entry: entry,
                                    refreshToken: refreshToken,
                                    onDefaultsChanged: onDefaultsChanged)
                    if i < entries.count - 1 {
                        Rectangle().fill(Theme.hairline).frame(height: 1)
                            .padding(.leading, 12)
                    }
                }
            }
            .padding(.trailing, 8)   // reserve a gutter for the scrollbar
        }
        .scrollContentBackground(.hidden)
        .scrollIndicators(.hidden)
        .scrollPosition($position)
        .onScrollGeometryChange(for: ScrollMetrics.self) { geo in
            ScrollMetrics(offset: geo.bounds.minY,
                          visible: geo.bounds.height,
                          content: geo.contentSize.height)
        } action: { _, new in
            metrics = new
        }
        .overlay(alignment: .trailing) {
            CustomScrollbar(metrics: metrics) { y in
                position.scrollTo(y: y)
            }
        }
    }
}

/// Custom, themed settings menu shown in a popover — matches the app's app-picker
/// dropdowns instead of the stock `NSMenu`. Appearance is an inline disclosure;
/// About/Quit are plain rows.
private struct SettingsMenuView: View {
    @Binding var appearance: String
    let onAbout: () -> Void
    let onQuit: () -> Void

    @State private var appearanceExpanded = false

    private let options: [(id: String, label: String)] = [
        ("system", "System"), ("light", "Light"), ("dark", "Dark")
    ]

    var body: some View {
        VStack(spacing: 2) {
            MenuRow(title: "Appearance") {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(appearanceExpanded ? 90 : 0))
            } action: {
                withAnimation(.smooth(duration: 0.2)) { appearanceExpanded.toggle() }
            }

            if appearanceExpanded {
                ForEach(options, id: \.id) { option in
                    MenuRow(title: option.label, indented: true) {
                        if appearance == option.id {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(Theme.accent)
                        }
                    } action: {
                        appearance = option.id
                    }
                }
            }

            Rectangle().fill(Theme.hairline).frame(height: 1)
                .padding(.vertical, 3)

            MenuRow(title: "About ExtSelector", action: onAbout)
            MenuRow(title: "Quit ExtSelector", action: onQuit)
        }
        .padding(6)
        .frame(width: 210)
        .background(Theme.windowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .presentationBackground(Theme.windowBackground)
    }
}

/// One row in the custom settings menu: title, optional trailing accessory, hover
/// highlight — mirroring the app-picker dropdown rows.
private struct MenuRow<Trailing: View>: View {
    let title: String
    var indented: Bool = false
    @ViewBuilder var trailing: () -> Trailing
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title).font(.subheadline).foregroundStyle(.primary)
                Spacer(minLength: 8)
                trailing()
            }
            .padding(.leading, indented ? 22 : 10)
            .padding(.trailing, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(hovering ? Theme.accent.opacity(0.22) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .onHover { hovering = $0 }
    }
}

extension MenuRow where Trailing == EmptyView {
    init(title: String, indented: Bool = false, action: @escaping () -> Void) {
        self.init(title: title, indented: indented, trailing: { EmptyView() }, action: action)
    }
}

/// One installed app and the catalog types it is currently the default for.
/// Feeds the reverse ("what opens with X?") search.
struct AppDefaults: Identifiable {
    let app: AppHandler
    let entries: [FileTypeEntry]
    var id: URL { app.url }
}

/// Reverse-search results: per matching app, a section listing every type it
/// opens, each with a one-tap reset to steer that type away from the app.
private struct ReverseResultsView: View {
    let matches: [AppDefaults]
    let onReset: (FileTypeEntry, AppHandler) -> Void

    @State private var metrics = ScrollMetrics()
    @State private var position = ScrollPosition()

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(matches) { match in
                    sectionHeader(for: match)
                    ForEach(Array(match.entries.enumerated()), id: \.element.id) { i, entry in
                        ReverseRow(entry: entry) { onReset(entry, match.app) }
                        if i < match.entries.count - 1 {
                            Rectangle().fill(Theme.hairline).frame(height: 1)
                                .padding(.leading, 12)
                        }
                    }
                }
            }
            .padding(.trailing, 8)
        }
        .scrollContentBackground(.hidden)
        .scrollIndicators(.hidden)
        .scrollPosition($position)
        .onScrollGeometryChange(for: ScrollMetrics.self) { geo in
            ScrollMetrics(offset: geo.bounds.minY,
                          visible: geo.bounds.height,
                          content: geo.contentSize.height)
        } action: { _, new in
            metrics = new
        }
        .overlay(alignment: .trailing) {
            CustomScrollbar(metrics: metrics) { y in
                position.scrollTo(y: y)
            }
        }
    }

    private func sectionHeader(for match: AppDefaults) -> some View {
        HStack(spacing: 8) {
            Image(nsImage: match.app.icon).resizable().frame(width: 18, height: 18)
            Text(match.app.name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Text("\(match.entries.count)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(.quaternary, in: Capsule())
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }
}

/// A single type row in reverse mode: its badge + name, and a reset button that
/// flips it off the matched app onto the system default.
private struct ReverseRow: View {
    let entry: FileTypeEntry
    let onReset: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let badge = entry.badge { BadgeChip(label: badge) }
            }
            .frame(width: 58, alignment: .leading)

            Text(entry.name).font(.subheadline).lineLimit(1)
            Spacer(minLength: 8)

            Button(action: onReset) {
                Label("Reset", systemImage: "arrow.uturn.backward")
                    .labelStyle(.titleAndIcon)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(hovering ? Theme.accent : .secondary)
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .help("Stop opening \(entry.name) with this app")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.rowHover)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .opacity(hovering ? 1 : 0)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}
