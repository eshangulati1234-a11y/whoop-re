import SwiftUI

/// Shown at launch until the band is connected, then fades into Home.
struct LaunchView: View {
    @EnvironmentObject private var band: BandManager
    var canSkip: Bool
    var skip: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var line: String {
        if band.ready { return "Connected" }
        let status = band.status
        return status == "Not connected" || status.isEmpty ? "Looking for your band…" : status
    }

    var body: some View {
        ZStack {
            Palette.background.ignoresSafeArea()
            VStack(spacing: 28) {
                Image(systemName: band.ready ? "checkmark.circle.fill" : "waveform.path.ecg")
                    .font(.system(size: 64,weight: .medium))
                    .foregroundStyle(band.ready ? Palette.green : Palette.strain)
                    .accessibilityHidden(true)
                if !band.ready { ProgressView().accessibilityLabel("Connecting to your band") }
                VStack(spacing: 8) {
                    Text("Pulse").font(Typo.number(30)).foregroundStyle(Palette.text)
                    Text(line).font(Typo.body(15)).foregroundStyle(Palette.muted)
                        .contentTransition(.opacity).animation(.easeInOut(duration: 0.25), value: line)
                }
                if canSkip {
                    Button("Continue without band", action: skip)
                        .font(Typo.body(14, weight: .semibold)).foregroundStyle(Palette.secondary)
                        .transition(.opacity)
                }
            }
            .padding(24)
        }
    }
}
