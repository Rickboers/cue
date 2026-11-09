import SwiftUI

struct SettingsView: View {
    @Bindable private var settings = PrompterSettings.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Scrolling") {
                    Picker("Mode", selection: $settings.mode) {
                        ForEach(FollowMode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if settings.mode == .auto {
                        SliderRow(title: "Speed", value: $settings.autoSpeed, range: 60...260, step: 5) {
                            "\(Int($0)) wpm"
                        }
                    }
                }

                Section {
                    Toggle("Voice Commands", isOn: $settings.voiceCommands)
                } header: {
                    Text("Voice Commands")
                } footer: {
                    Text(settings.voiceCommands ? "Say \u{201C}go back\u{201D} · \u{201C}back two lines\u{201D} · \u{201C}skip ahead\u{201D} · \u{201C}next sentence\u{201D} · \u{201C}back to the top\u{201D} · \u{201C}next point\u{201D} · \u{201C}pause prompter\u{201D}. Commands that are part of your script are read, not obeyed." : "Off — Cue only follows along and never acts on what you say.")
                }

                Section("Text") {
                    SliderRow(title: "Size", value: $settings.fontSize, range: 18...56, step: 1) { "\(Int($0)) pt" }
                    SliderRow(title: "Side margins", value: $settings.margin, range: 8...80, step: 2) { "\(Int($0))" }
                    SliderRow(title: "Line spacing", value: $settings.lineSpacing, range: 1.0...1.9, step: 0.05) {
                        String(format: "%.2f", $0)
                    }
                    SliderRow(title: "Current line", value: $settings.readingLine, range: 0...0.45, step: 0.01) {
                        $0 < 0.02 ? "Top" : "\(Int($0 * 100))% down"
                    }
                    Toggle("Darken spoken words", isOn: $settings.dimSpoken)
                }

                Section {
                    Picker("Recording", selection: $settings.shape) {
                        ForEach(WindowShape.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Floating Window")
                } footer: {
                    Text("Upright: a wide strip — pinch it to full width and drag it right under the front camera. Landscape: a column whose text turns with the phone — drag it to the camera side.")
                }

                Section {
                    SliderRow(title: "Sensitivity", value: $settings.tiltSensitivity, range: 0.4...2, step: 0.1) {
                        String(format: "%.1f×", $0)
                    }
                    Toggle("Reverse direction", isOn: $settings.tiltReversed)
                    Toggle("Tilt in Voice mode too", isOn: $settings.tiltInVoice)
                } header: {
                    Text("Tilt")
                } footer: {
                    Text("Tip the top of the phone away from you to scroll forward, toward you to go back.")
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

private struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let label: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(label(value))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: $value, in: range, step: step)
        }
        .padding(.vertical, 2)
    }
}
