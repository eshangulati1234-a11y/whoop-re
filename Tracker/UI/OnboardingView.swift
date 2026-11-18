import SwiftUI
import UIKit

struct OnboardingView: View {
    var finish: () -> Void
    @AppStorage(HealthEngine.profileKey) private var profileData = Data()
    @State private var page = 0
    @State private var editingProfile = false
    @State private var savedProfile = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch page {
                    case 0:
                        Image("PulseLogo")
                            .resizable().scaledToFit().frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                            .accessibilityHidden(true)
                        Text("Welcome to Pulse").font(.largeTitle.bold())
                        Text("Set up your band and add your details to see your heart rate, sleep, and workouts.")
                            .foregroundStyle(.secondary)
                        Button("Get started") { page = 1 }.buttonStyle(PillButtonStyle())
                    case 1:
                        BandSetupContent { page = 2 }
                    default:
                        Text("Your details").font(.largeTitle.bold())
                        Text("Pulse uses your age, height and weight to estimate calories and heart-rate zones.")
                            .foregroundStyle(.secondary)
                        Button("Add my details") { editingProfile = true }.buttonStyle(PillButtonStyle())
                    }
                    Button("Set up later", action: finish)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .padding(24)
            }
            .screenBackground()
            .sheet(isPresented: $editingProfile, onDismiss: {
                if savedProfile { finish() }
            }) {
                NavigationStack { ProfileView() }
            }
            .onChange(of: profileData) { _, _ in
                savedProfile = HealthEngine.loadProfile() != nil
            }
        }
    }
}

struct BandSetupSheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                BandSetupContent { dismiss() }.padding(24)
            }
            .screenBackground()
            .navigationTitle("Band setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

private struct BandSetupContent: View {
    @EnvironmentObject private var band: BandManager
    @Environment(\.openURL) private var openURL
    var paired: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.largeTitle).foregroundStyle(Palette.strain)
                .accessibilityHidden(true)
            Text("Set up your band").font(.largeTitle.bold())
            Text("Slide the charged battery pack onto your WHOOP 4.0 to wake it. Keep it close to your iPhone.")
                .foregroundStyle(.secondary)
            switch band.bandSetup {
            case .idle, .looking:
                ProgressView("Looking for your band…")
            case .confirm(let name):
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        Label(name, systemImage: "waveform.path.ecg").font(.headline)
                        Button("Confirm my band") { band.confirmBandSetup() }
                            .buttonStyle(PillButtonStyle())
                    }
                }
            case .connecting:
                ProgressView("Connecting to your band…")
            case .complete:
                Label("Band connected", systemImage: "checkmark.circle.fill").foregroundStyle(Palette.green)
            case .help(let message), .waitingForBluetooth(let message):
                Text(message).foregroundStyle(.secondary)
                if band.bandSetupNeedsSettings, let settings = URL(string: UIApplication.openSettingsURLString) {
                    Button("Open Settings") { openURL(settings) }.buttonStyle(.bordered)
                }
                Button("Try again") { band.retryBandSetup() }.buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { band.beginBandSetup() }
        .onDisappear { band.cancelBandSetup() }
        .onChange(of: band.bandSetup) { _, state in
            if state == .complete { paired() }
        }
    }
}
