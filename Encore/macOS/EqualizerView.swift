import SwiftUI
import EncoreCore

/// The equalizer popover shown from the player bar: enable toggle, preset
/// menu, preamp, and ten draggable band sliders.
struct EqualizerView: View {
    @EnvironmentObject var player: PlayerEngine

    private var eq: Binding<EQSettings> { $player.eqSettings }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Equalizer")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Toggle("", isOn: eq.enabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }

            HStack(spacing: 8) {
                Menu {
                    ForEach(Equalizer.presets, id: \.name) { preset in
                        Button {
                            var s = player.eqSettings
                            s.gains = preset.gains
                            s.presetName = preset.name
                            if !s.enabled { s.enabled = true }
                            player.eqSettings = s
                        } label: {
                            if player.eqSettings.presetName == preset.name {
                                Label(preset.name, systemImage: "checkmark")
                            } else {
                                Text(preset.name)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "slider.horizontal.3").font(.system(size: 11))
                        Text(player.eqSettings.presetName ?? "Custom")
                            .font(.system(size: 12, weight: .medium))
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Spacer()

                Button("Reset") {
                    player.eqSettings = EQSettings(enabled: player.eqSettings.enabled)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
            }

            HStack(alignment: .bottom, spacing: 10) {
                // Preamp column, set apart from the bands.
                bandColumn(label: "Pre", value: eq.preamp, tint: Theme.textSecondary)
                Rectangle().fill(Theme.stroke).frame(width: 1, height: 150)
                ForEach(0..<Equalizer.bandCount, id: \.self) { i in
                    bandColumn(label: Equalizer.label(forBand: i),
                               value: bandBinding(i),
                               tint: Theme.fallbackAccent)
                }
            }
            .opacity(player.eqSettings.enabled ? 1 : 0.45)
        }
        .padding(16)
        .frame(width: 460)
        .background(Theme.bgElevated)
    }

    /// A binding to one band that also clears the preset label when edited.
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
            Text(gainText(value.wrappedValue))
                .font(.system(size: 9, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.textTertiary)
            VerticalGainSlider(value: value, tint: tint)
                .frame(width: 26, height: 150)
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private func gainText(_ v: Double) -> String {
        v == 0 ? "0" : String(format: "%+.0f", v)
    }
}

/// A vertical slider for a −12…+12 dB gain: track, filled center-out portion,
/// and a draggable thumb. Double-click resets to 0.
struct VerticalGainSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = Equalizer.gainRange
    var tint: Color

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let thumb: CGFloat = 12
            let usable = h - thumb
            let frac = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
            let y = thumb / 2 + usable * (1 - frac)
            let mid = thumb / 2 + usable * 0.5

            ZStack(alignment: .top) {
                Capsule()
                    .fill(Theme.card)
                    .frame(width: 4)
                    .frame(maxWidth: .infinity)
                // Fill from center to the thumb (so boost fills up, cut fills down).
                Capsule()
                    .fill(tint.opacity(0.9))
                    .frame(width: 4, height: abs(y - mid))
                    .offset(y: min(y, mid))
                    .frame(maxWidth: .infinity, alignment: .top)
                Circle()
                    .fill(.white)
                    .frame(width: thumb, height: thumb)
                    .shadow(radius: 1, y: 0.5)
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
            .onTapGesture(count: 2) { value = 0 }
        }
    }
}
