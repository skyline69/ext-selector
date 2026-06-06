import SwiftUI

/// macOS 26 Liquid Glass category selector with a sliding selection.
///
/// A SINGLE Liquid Glass pill lives on its own layer behind the icons and slides
/// left/right via `matchedGeometryEffect`: every icon publishes its frame as a
/// source (`id: index`), and the pill consumes the frame of whichever index is
/// selected (`id: selected`). Changing the selection inside `withAnimation`
/// animates the pill's frame from the old icon to the new one.
///
/// The glyphs are drawn in TWO layers so they invert correctly as the pill
/// passes under them:
///   • a base layer in `.secondary` (the resting, unselected look), and
///   • a white layer **masked to the pill's capsule**, so any glyph the pill
///     currently covers shows white.
/// Without the masked layer, icons the pill slides over would read as dark
/// glyphs on the bright accent fill (the "black icons" artifact).
struct CategoryNavBar: View {
    let categories: [Category]
    @Binding var selected: Int

    @Namespace private var ns
    private let itemWidth: CGFloat = 34
    private let itemHeight: CGFloat = 28

    var body: some View {
        ZStack {
            // Layer 1: the sliding glass pill (behind the icons).
            GlassEffectContainer {
                Capsule()
                    .fill(.clear)
                    .glassEffect(
                        .regular.tint(Theme.accent.opacity(0.9)).interactive(),
                        in: .capsule
                    )
                    .frame(width: itemWidth, height: itemHeight)
                    .matchedGeometryEffect(id: selected, in: ns, isSource: false)
            }

            // Layer 2: base glyphs (secondary) — also the tap targets + the
            // matchedGeometry frame sources.
            iconRow(interactive: true)

            // Layer 3: white glyphs, revealed only where the pill capsule is.
            // As the pill slides, the mask slides with it and the covered glyphs
            // turn white instead of staying dark.
            iconRow(interactive: false)
                .foregroundStyle(.white)
                .mask {
                    Capsule()
                        .frame(width: itemWidth, height: itemHeight)
                        .matchedGeometryEffect(id: selected, in: ns, isSource: false)
                }
                .allowsHitTesting(false)
        }
        .padding(4)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
    }

    /// One row of category glyphs. The interactive copy carries the buttons and
    /// publishes frame sources; the overlay copy is purely visual.
    @ViewBuilder
    private func iconRow(interactive: Bool) -> some View {
        HStack(spacing: 2) {
            ForEach(Array(categories.enumerated()), id: \.element.id) { index, category in
                let glyph = Image(systemName: category.sfSymbol)
                    .font(.system(size: 13, weight: index == selected ? .bold : .semibold))
                    .frame(width: itemWidth, height: itemHeight)

                if interactive {
                    Button {
                        withAnimation(.smooth(duration: 0.4, extraBounce: 0.2)) {
                            selected = index
                        }
                    } label: {
                        glyph.foregroundStyle(.secondary).contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .pointerStyle(.link)
                    .matchedGeometryEffect(id: index, in: ns, isSource: true)
                    .help(category.name)
                } else {
                    glyph
                }
            }
        }
    }
}
