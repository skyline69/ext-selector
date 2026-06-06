import SwiftUI
import UniformTypeIdentifiers

struct FileTypeRowView: View {
    let entry: FileTypeEntry
    /// Bumped by the parent (e.g. on app re-focus) to force a fresh reload.
    var refreshToken: Int = 0
    /// Called after this row changes a default (set or reset), so the parent can
    /// rebuild anything derived from defaults (e.g. the reverse-lookup index).
    var onDefaultsChanged: () -> Void = {}

    /// One exhaustive state — no illegal combinations of loose flags.
    enum State {
        case loading
        case unknownType(reason: String)
        case noHandlers
        case ready(current: AppHandler?, candidates: [AppHandler])
    }

    @SwiftUI.State private var state: State = .loading
    @SwiftUI.State private var busy = false
    @SwiftUI.State private var failure: String?
    @SwiftUI.State private var hovering = false
    @SwiftUI.State private var pickerOpen = false

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let badge = entry.badge { BadgeChip(label: badge) }
            }
            .frame(width: 58, alignment: .leading)

            Text(entry.name)
                .font(.subheadline)
                .lineLimit(1)

            Spacer(minLength: 8)

            if hovering, currentHandler != nil {
                Button { reset() } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
                .disabled(busy)
                .help("Reset to system default")
                .transition(.opacity)
            }

            trailing
                .frame(width: 150, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.rowHover)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .opacity(hovering ? 1 : 0)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .task(id: refreshToken) { await reload() }
    }

    @ViewBuilder
    private var trailing: some View {
        if let failure {
            Label(failure, systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange).lineLimit(1)
        } else {
            switch state {
            case .loading:
                ProgressView().controlSize(.small)
            case .unknownType:
                Text("unmanaged").font(.caption).foregroundStyle(.tertiary)
            case .noHandlers:
                Text("no apps").font(.caption).foregroundStyle(.tertiary)
            case let .ready(current, candidates):
                picker(current: current, candidates: candidates)
            }
        }
    }

    private func picker(current: AppHandler?, candidates: [AppHandler]) -> some View {
        Button {
            pickerOpen.toggle()
        } label: {
            HStack(spacing: 6) {
                if let current {
                    Image(nsImage: current.icon).resizable().frame(width: 16, height: 16)
                    Text(current.name).font(.subheadline).foregroundStyle(.primary).lineLimit(1)
                } else {
                    Text("Choose…").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(hovering || pickerOpen ? Theme.accent : .secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovering || pickerOpen ? Theme.accent.opacity(0.16) : Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(hovering || pickerOpen ? Theme.accent.opacity(0.55) : Theme.surfaceStroke,
                                  lineWidth: 1)
            )
            .animation(.easeOut(duration: 0.12), value: hovering || pickerOpen)
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .disabled(busy)
        .popover(isPresented: $pickerOpen, arrowEdge: .bottom) {
            AppDropdown(candidates: candidates, current: current) { app in
                pickerOpen = false
                apply(app, current: current)
            }
        }
    }

    /// The app currently set as default, when the row is loaded and ready.
    private var currentHandler: AppHandler? {
        if case .ready(let current, _) = state { return current }
        return nil
    }

    private func reload() async {
        switch entry.resolution {
        case .unresolved(let reason):
            state = .unknownType(reason: reason)
        case .resolved(let target):
            let snapshot = await HandlerStore.shared.snapshot(for: target)
            state = snapshot.hasHandlers
                ? .ready(current: snapshot.current, candidates: snapshot.candidates)
                : .noHandlers
        }
    }

    private func apply(_ app: AppHandler, current: AppHandler?) {
        guard case .resolved(let target) = entry.resolution else { return }
        // Already the default — skip the call so macOS doesn't pop the
        // "Use X / Keep Y" confirmation for a no-op change.
        guard app != current else { return }

        busy = true
        failure = nil
        Task {
            do {
                try await LaunchServicesManager.setDefault(app.url, for: target)
            } catch {
                // Swallow here: the system prompt's "Keep <old>" choice also
                // surfaces as a throw. Truth comes from re-reading the default.
            }
            // The default just changed — drop the stale cache entry, re-read truth.
            await HandlerStore.shared.invalidate(target)
            let snapshot = await HandlerStore.shared.snapshot(for: target)
            if snapshot.hasHandlers {
                state = .ready(current: snapshot.current, candidates: snapshot.candidates)
                if snapshot.current != app && snapshot.current != current {
                    failure = "Could not set \(app.name)"
                }
            } else {
                state = .noHandlers
            }
            busy = false
            onDefaultsChanged()
        }
    }

    /// Re-point this type to the system's suggested handler (best-effort, see
    /// `LaunchServicesManager.systemSuggestedHandler`). Silent — no per-item
    /// confirmation prompt.
    private func reset() {
        guard case .resolved(let target) = entry.resolution else { return }
        busy = true
        failure = nil
        Task {
            let snapshot = await HandlerStore.shared.snapshot(for: target)
            guard let suggested = LaunchServicesManager.suggestedHandler(
                    candidates: snapshot.candidates, current: snapshot.current),
                  suggested != snapshot.current,
                  let bundleID = suggested.bundleID else {
                busy = false
                return
            }
            LaunchServicesManager.setDefaultSilently(bundleID: bundleID, for: target)
            await HandlerStore.shared.invalidate(target)
            let fresh = await HandlerStore.shared.snapshot(for: target)
            state = fresh.hasHandlers
                ? .ready(current: fresh.current, candidates: fresh.candidates)
                : .noHandlers
            busy = false
            onDefaultsChanged()
        }
    }
}

/// Themed dropdown list of candidate apps for the custom picker popover.
struct AppDropdown: View {
    let candidates: [AppHandler]
    let current: AppHandler?
    let onSelect: (AppHandler) -> Void

    @State private var hovered: AppHandler.ID?
    @State private var metrics = ScrollMetrics()
    @State private var position = ScrollPosition()

    var body: some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(candidates) { app in
                    Button {
                        onSelect(app)
                    } label: {
                        HStack(spacing: 9) {
                            Image(nsImage: app.icon).resizable().frame(width: 18, height: 18)
                            Text(app.name).font(.subheadline).foregroundStyle(.primary).lineLimit(1)
                            Spacer(minLength: 8)
                            if app == current {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(Theme.accent)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(hovered == app.id ? Theme.accent.opacity(0.22) : .clear)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .pointerStyle(.link)
                    .onHover { hovered = $0 ? app.id : (hovered == app.id ? nil : hovered) }
                }
            }
            // Equal horizontal insets so row highlights are symmetric; the extra
            // right space doubles as the scrollbar gutter.
            .padding(.vertical, 6)
            .padding(.horizontal, 12)
        }
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
            CustomScrollbar(metrics: metrics, topInset: 14, bottomInset: 14) { y in
                position.scrollTo(y: y)
            }
        }
        .frame(width: 230)
        .frame(maxHeight: 300)
        .background(Theme.windowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .presentationBackground(Theme.windowBackground)
    }
}
