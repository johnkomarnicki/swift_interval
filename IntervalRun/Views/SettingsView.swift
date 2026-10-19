import SwiftUI

struct SettingsView: View {
    @AppStorage(AppSettings.beepVolumeKey) private var beepVolume = AppSettings.defaultBeepVolume
    @AppStorage(AppSettings.vibrateOnCountdownKey) private var vibrateOnCountdown = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Image(systemName: "speaker.fill")
                            .foregroundStyle(.secondary)
                        Slider(value: $beepVolume, in: 0.1...1)
                        Image(systemName: "speaker.wave.3.fill")
                            .foregroundStyle(.secondary)
                    }
                    Button("Test Sound", systemImage: "play.circle") {
                        let audio = AudioCueScheduler.shared
                        audio.volume = Float(beepVolume)
                        audio.vibrateOnCountdown = vibrateOnCountdown
                        audio.playTestSound()
                    }
                } header: {
                    Text("Beep volume")
                } footer: {
                    Text("Relative to your phone's volume. Beeps play even with the silent switch on, and briefly lower music from other apps.")
                }

                Section {
                    Toggle("Vibrate with countdown beeps", isOn: $vibrateOnCountdown)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
