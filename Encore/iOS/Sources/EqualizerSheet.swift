import SwiftUI
import EncoreCore

/// iOS equalizer: enable toggle, a horizontal presets row, preamp, and ten
/// draggable band sliders.
struct EqualizerSheet: View {
    @EnvironmentObject var player: PlayerEngine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                // Presets.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Equalizer.presets, id: \.name) { preset in
                            let active = player.eqSettings.presetName == preset.name
                            Button {
                                var s = player.eqSettings
                                s.gains = preset.gains
                                s.presetName = preset.name
                                if !s.enabled { s.enabled = true }
                                player.eqSettings = s
                            } label: {
                                Text(preset.name)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(active ? .black : Theme.textPrimary)
                                    .padding(.horizontal, 14).padding(.vertical, 7)
                                    .background(active ? Theme.accent : Theme.card, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }

                // Bands + preamp.
                HStack(alignment: .bottom, spacing: 6) {
                    bandColumn(label: "Pre", value: preampBinding, tint: Theme.textSecondary)
                    Rectangle().fill(Theme.stroke).frame(width: 1, height: 150)
                    ForEach(0..<Equalizer.bandCount, id: \.self) { i in
                        bandColumn(label: Equalizer.label(forBand: i),
                                   value: bandBinding(i),
                                   tint: Theme.accent)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 12)
                .opacity(player.eqSettings.enabled ? 1 : 0.4)

                Spacer(minLength: 0)
            }
            .padding(.top, 12)
            .background(Theme.bg)
            .navigationTitle("Equalizer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Reset") {
                        player.eqSettings = EQSettings(enabled: player.eqSettings.enabled)
                    }
                }
                ToolbarItem(placement: .principal) {
                    Toggle("", isOn: Binding(
                        get: { player.eqSettings.enabled },
                        set: { player.eqSettings.enabled = $0 }
                    ))
                    .labelsHidden()
                    .tint(Theme.accent)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var preampBinding: Binding<Double> {
        Binding(get: { player.eqSettings.preamp },
                set: { player.eqSettings.preamp = $0 })
    }

    private func bandBinding(_ i: Int) -> Binding<Double> {
        Binding(
            get: { player.eqSettings.gains.indices.contains(i) ? player.eqSettings.gains[i] : 0 },
            set: { newValue in
                var s = player.eqSettings
                guard s.gains.indices.contains(i) else { return }
                s.gains[i] = newValue
                s.presetName = Equalizer.matchingPresetName(s.gains)
                if !s.enabled { s.enabled = true }
                player.eqSettings = s
            }
        )
    }

    private func bandColumn(label: String, value: Binding<Double>, tint: Color) -> some View {
        VStack(spacing: 6) {
            Text(value.wrappedValue == 0 ? "0" : String(format: "%+.0f", value.wrappedValue))
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.textTertiary)
            VerticalGainSlider(value: value, tint: tint)
                .frame(width: 30, height: 150)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
        }
    }
}

/// Vertical −12…+12 dB slider: track, center-out fill, draggable thumb.
struct VerticalGainSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = Equalizer.gainRange
    var tint: Color

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let thumb: CGFloat = 16
            let usable = h - thumb
            let frac = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
            let y = thumb / 2 + usable * (1 - frac)
            let mid = thumb / 2 + usable * 0.5

            ZStack(alignment: .top) {
                Capsule().fill(Theme.card).frame(width: 5).frame(maxWidth: .infinity)
                Capsule()
                    .fill(tint.opacity(0.9))
                    .frame(width: 5, height: abs(y - mid))
                    .offset(y: min(y, mid))
                    .frame(maxWidth: .infinity, alignment: .top)
                Circle()
                    .fill(.white)
                    .frame(width: thumb, height: thumb)
                    .shadow(radius: 1.5, y: 1)
                    .offset(y: y - thumb / 2)
                    .frame(maxWidth: .infinity)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let clampedY = min(max(g.location.y, thumb / 2), h - thumb / 2)
                        let f = 1 - (clampedY - thumb / 2) / usable
                        value = (range.lowerBound + f * (range.upperBound - range.lowerBound))
                            .rounded()
                    }
            )
        }
    }
}
