import SwiftUI

/// Scroll position/size snapshot, derived from `ScrollGeometry`.
struct ScrollMetrics: Equatable {
    var offset: CGFloat = 0      // distance scrolled from the top
    var visible: CGFloat = 0     // height of the visible viewport
    var content: CGFloat = 0     // total content height

    var isScrollable: Bool { content > visible + 1 }
}

/// A slim, themed scrollbar. Reflects scroll position, brightens on hover, and
/// can be grabbed to scroll (calls back with a target y offset). Auto-hides a
/// beat after the last interaction. Only the thumb (a narrow right-edge column)
/// captures hits, so it never blocks the rows.
struct CustomScrollbar: View {
    let metrics: ScrollMetrics
    var topInset: CGFloat = 4
    var bottomInset: CGFloat = 16
    var onScrollTo: (CGFloat) -> Void

    private let thumbWidth: CGFloat = 5
    private let minThumb: CGFloat = 28
    private let hitInset: CGFloat = 5   // widens the grab area without widening the visual

    @State private var scrolledRecently = false
    @State private var hovering = false
    @State private var dragStartOffset: CGFloat?
    @State private var lastActivity = ContinuousClock.now
    @State private var hideLoopRunning = false

    private var shown: Bool { scrolledRecently || hovering || dragStartOffset != nil }

    var body: some View {
        GeometryReader { geo in
            let track = geo.size.height
            if metrics.isScrollable {
                let ratio = metrics.visible / metrics.content
                let thumb = max(minThumb, track * ratio)
                let maxOffset = max(metrics.content - metrics.visible, 0)
                let scrollable = max(track - thumb, 1)
                let fraction = maxOffset > 0 ? min(max(metrics.offset / maxOffset, 0), 1) : 0
                let y = fraction * scrollable

                HStack {
                    Spacer(minLength: 0)
                    Capsule()
                        .fill(Theme.accent.opacity(shown ? 0.9 : 0.4))
                        .frame(width: thumbWidth, height: thumb)
                        .offset(y: y)
                        .padding(.horizontal, hitInset)
                        .contentShape(Rectangle())
                        .pointerStyle(.grabIdle)
                        .gesture(dragGesture(scrollable: scrollable, maxOffset: maxOffset))
                        .onHover { hovering = $0; if !$0 { scheduleHide() } }
                        .animation(.easeOut(duration: 0.15), value: shown)
                }
            }
        }
        // Keep the track clear of rounded corners so the thumb never clips.
        .padding(.trailing, 4)
        .padding(.top, topInset)
        .padding(.bottom, bottomInset)
        .onChange(of: metrics.offset) { _, _ in pulse() }
    }

    private func dragGesture(scrollable: CGFloat, maxOffset: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragStartOffset == nil { dragStartOffset = metrics.offset }
                let deltaFraction = value.translation.height / scrollable
                let target = (dragStartOffset ?? 0) + deltaFraction * maxOffset
                onScrollTo(min(max(target, 0), maxOffset))
            }
            .onEnded { _ in
                dragStartOffset = nil
                scheduleHide()
            }
    }

    /// Mark activity (cheap, per-frame safe) and ensure a single hide-loop runs —
    /// instead of spawning a Task on every scroll frame.
    private func pulse() {
        lastActivity = ContinuousClock.now
        scrolledRecently = true
        scheduleHide()
    }

    private func scheduleHide() {
        lastActivity = ContinuousClock.now
        guard !hideLoopRunning else { return }
        hideLoopRunning = true
        Task {
            let quiet = Duration.milliseconds(1100)
            while true {
                let elapsed = ContinuousClock.now - lastActivity
                if elapsed >= quiet {
                    if dragStartOffset == nil && !hovering { scrolledRecently = false }
                    hideLoopRunning = false
                    return
                }
                try? await Task.sleep(for: quiet - elapsed)
            }
        }
    }
}
