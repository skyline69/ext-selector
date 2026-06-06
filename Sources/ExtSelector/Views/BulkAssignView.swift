import SwiftUI
import AppKit

/// One resolvable type in a category, plus the precomputed facts the bulk
/// checklist needs: which apps can open it, and its current default. Carries
/// URLs (not `AppHandler`s) so compatibility checks are cheap set lookups.
struct BulkTypeInfo: Identifiable, Hashable {
    var id: String { entry.id }
    let entry: FileTypeEntry
    let target: HandlerTarget
    let candidateURLs: Set<URL>
    let currentURL: URL?

    func canOpen(_ app: AppHandler) -> Bool { candidateURLs.contains(app.url) }
    func isCurrent(_ app: AppHandler) -> Bool { currentURL == app.url }
}

/// Two-phase bulk-assign popover. First pick an app; then tick which of the
/// category's types to point at it. Types the app can't open are shown disabled,
/// so an app is never applied to an incompatible type.
struct BulkAssignView: View {
    let apps: [AppHandler]
    let types: [BulkTypeInfo]
    let onApply: (AppHandler, [HandlerTarget]) -> Void

    @State private var selected: AppHandler?
    /// `BulkTypeInfo.id`s currently ticked (only meaningful in phase two).
    @State private var checked: Set<String> = []
    @State private var hovered: AppHandler.ID?

    var body: some View {
        ZStack {
            if let app = selected {
                // Pushes in from the right; on back it slides back out right.
                typeChecklist(for: app)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                // Sits "behind"; slides off to the left when a type list pushes in.
                appPicker
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .frame(width: 270)
        .frame(maxHeight: 320)
        .animation(.snappy(duration: 0.28), value: selected)
        .background(Theme.windowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .presentationBackground(Theme.windowBackground)
    }

    // MARK: Phase one — pick the app

    private var appPicker: some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(apps) { app in
                    Button { select(app) } label: {
                        HStack(spacing: 9) {
                            Image(nsImage: app.icon).resizable().frame(width: 18, height: 18)
                            Text(app.name).font(.subheadline).foregroundStyle(.primary).lineLimit(1)
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.tertiary)
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
            .padding(.vertical, 6)
            .padding(.horizontal, 12)
        }
        .scrollIndicators(.automatic)
    }

    /// Tick every type the app can open by default, so "set all" stays one tap
    /// for the common case; the user unticks anything they want to keep.
    private func select(_ app: AppHandler) {
        checked = Set(types.filter { $0.canOpen(app) }.map(\.id))
        selected = app
    }

    // MARK: Phase two — tick the types

    private func typeChecklist(for app: AppHandler) -> some View {
        VStack(spacing: 0) {
            header(for: app)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(types) { info in typeRow(info, app: app) }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 12)
            }
            .scrollIndicators(.automatic)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            footer(for: app)
        }
    }

    private func header(for app: AppHandler) -> some View {
        HStack(spacing: 8) {
            Button { selected = nil } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .help("Back to apps")
            Image(nsImage: app.icon).resizable().frame(width: 18, height: 18)
            Text(app.name).font(.subheadline.weight(.semibold)).lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func typeRow(_ info: BulkTypeInfo, app: AppHandler) -> some View {
        let supported = info.canOpen(app)
        let isOn = checked.contains(info.id)
        return Button {
            guard supported else { return }
            if isOn { checked.remove(info.id) } else { checked.insert(info.id) }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .font(.system(size: 15))
                    .foregroundStyle(isOn ? Theme.accent : Color.secondary)
                    .contentTransition(.symbolEffect(.replace))
                    .animation(.snappy(duration: 0.15), value: isOn)
                if let badge = info.entry.badge { BadgeChip(label: badge) }
                Text(info.entry.name)
                    .font(.subheadline)
                    .foregroundStyle(supported ? .primary : .secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if !supported {
                    Text("can't open")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else if info.isCurrent(app) {
                    Text("current")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .opacity(supported ? 1 : 0.55)
        }
        .buttonStyle(.plain)
        .pointerStyle(supported ? .link : .default)
        .disabled(!supported)
    }

    private func footer(for app: AppHandler) -> some View {
        let targets = applyTargets(for: app)
        return HStack {
            Spacer()
            Button { onApply(app, targets) } label: {
                Text(targets.isEmpty ? "Nothing to change"
                                     : "Set \(targets.count) type\(targets.count == 1 ? "" : "s")")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .disabled(targets.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    /// Ticked, openable types that aren't already on this app — what Apply changes.
    private func applyTargets(for app: AppHandler) -> [HandlerTarget] {
        types.filter { checked.contains($0.id) && $0.canOpen(app) && !$0.isCurrent(app) }
             .map(\.target)
    }
}
