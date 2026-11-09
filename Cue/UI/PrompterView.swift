import SwiftUI

/// Owns the engine for the life of the prompter screen; `@StateObject` builds it exactly once.
final class PrompterSession: ObservableObject {
    let engine: PrompterEngine
    @Published var showSettings = false

    init(script: Script) {
        engine = PrompterEngine(script: script)
    }
}

struct PrompterView: View {
    let script: Script

    @Environment(\.dismiss) private var dismiss
    @Environment(ScriptStore.self) private var store
    @StateObject private var session: PrompterSession

    init(script: Script) {
        self.script = script
        _session = StateObject(wrappedValue: PrompterSession(script: script))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            PrompterScreen(engine: session.engine, showSettings: $session.showSettings,
                           onRename: rename) {
                close()
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .onAppear { session.engine.start() }
        .sheet(isPresented: $session.showSettings) {
            SettingsView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }

    private func rename(_ title: String) {
        session.engine.title = title
        if var s = store.script(script.id) {
            s.title = title
            store.update(s)
        }
    }

    private func close() {
        let engine = session.engine
        engine.stop()
        if var s = store.script(script.id), s.pointsLayout != engine.pointsLayout {
            s.pointsLayout = engine.pointsLayout
            store.update(s)
        }
        dismiss()
    }
}

/// Laid out for the right thumb: the less you need something, the further left and higher up it sits.
/// The two things you reach for all the time — Play/Pause and Float — are stacked in the bottom-right corner.
private struct PrompterScreen: View {
    @Bindable var engine: PrompterEngine
    @Binding var showSettings: Bool
    let onRename: (String) -> Void
    let onClose: () -> Void
    @State private var renaming = false
    @Bindable private var settings = PrompterSettings.shared

    var body: some View {
        VStack(spacing: 14) {
            header

            // The prompter only gets the space the controls leave, so the controls are never pushed off
            // screen. It hangs from the top with its status right under it; spare room collects above the controls.
            VStack(spacing: 12) {
                PrompterCanvas(engine: engine)
                    .aspectRatio(engine.canvasAspect, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .strokeBorder(.white.opacity(0.1), lineWidth: 1)
                    )
                status
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 6)
            .layoutPriority(-1)

            if engine.mode == .auto && engine.pointsLayout != .only {
                HStack(spacing: 12) {
                    Image(systemName: "tortoise.fill").foregroundStyle(.secondary)
                    Slider(value: $settings.autoSpeed, in: 60...260, step: 5)
                    Image(systemName: "hare.fill").foregroundStyle(.secondary)
                }
                .font(.footnote)
                .padding(.horizontal, 8)
            }

            transport

            bottomBar
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
        // Fixed-size controls: very large system text would push labels into each other.
        .dynamicTypeSize(.xSmall ... .xLarge)
        .animation(.snappy, value: engine.mode)
        .animation(.snappy, value: settings.shape)
        .animation(.snappy, value: engine.isFloating)
        .sensoryFeedback(.selection, trigger: settings.mode)
        .sensoryFeedback(.selection, trigger: settings.shape)
        .sensoryFeedback(.selection, trigger: settings.fontSize)
        .sensoryFeedback(.selection, trigger: engine.pointsLayout)
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 0) {
                Button {
                    showSettings = true
                } label: {
                    BarItem(systemName: "gearshape", title: "Settings")
                }
                .barSlot()

                Menu {
                    Picker("Text Size", selection: $settings.fontSize) {
                        Text("Small").tag(18.0)
                        Text("Medium").tag(22.0)
                        Text("Large").tag(28.0)
                        Text("Extra Large").tag(36.0)
                    }
                } label: {
                    BarItem(systemName: "textformat.size", title: "Text")
                }
                .barSlot()

                if !engine.points.isEmpty {
                    Menu {
                        Picker("Talking Points", selection: $engine.pointsLayout) {
                            Label("Script Only", systemImage: "text.alignleft").tag(PointsLayout.off)
                            Label("Script + Points", systemImage: "text.badge.star").tag(PointsLayout.pinned)
                            Label("Points Only", systemImage: "list.bullet").tag(PointsLayout.only)
                        }
                    } label: {
                        BarItem(systemName: "list.bullet", title: "Points")
                    }
                    .barSlot()
                }

                // A menu with both choices and a check, like Text and Mode — a toggle that shows the
                // current state reads backwards.
                Menu {
                    Picker("Recording", selection: $settings.shape) {
                        Label("Upright", systemImage: "iphone").tag(WindowShape.upright)
                        Label("Landscape", systemImage: "iphone.landscape").tag(WindowShape.landscape)
                    }
                } label: {
                    BarItem(systemName: settings.shape == .upright ? "iphone" : "iphone.landscape",
                            title: settings.shape.title)
                }
                .barSlot()
                .accessibilityHint("How you hold the phone while recording")

                Menu {
                    Picker("Scroll By", selection: $settings.mode) {
                        ForEach(FollowMode.allCases) { mode in
                            Label(mode.title, systemImage: icon(for: mode)).tag(mode)
                        }
                    }
                } label: {
                    BarItem(systemName: icon(for: settings.mode), title: settings.mode.title)
                }
                .barSlot()
            }
            .padding(.horizontal, 4)
            .frame(height: 64)
            .background(.white.opacity(0.13), in: Capsule())

            floatButton
        }
    }

    private var floatButton: some View {
        Button {
            engine.float()
        } label: {
            VStack(spacing: 3) {
                Image(systemName: engine.isFloating ? "pip.exit" : "pip.enter")
                    .font(.system(size: 20, weight: .bold))
                    .frame(width: 30, height: 26)
                Text(engine.isFloating ? "Return" : "Float")
                    .font(.caption2.weight(.bold))
            }
            .foregroundStyle(.black)
            .frame(width: Self.cornerWidth, height: 64)
            .background(Color.cueAccent, in: Capsule())
        }
        .opacity(!engine.canFloat && !engine.isFloating ? 0.45 : 1)
        .disabled(!engine.canFloat && !engine.isFloating)
        .accessibilityLabel(engine.isFloating ? "Return to app" : "Float over Camera")
    }

    /// The bottom-right column (Play/Pause over Float) shares one width so it reads as a unit.
    private static let cornerWidth: CGFloat = 78


    private func icon(for mode: FollowMode) -> String {
        switch mode {
        case .voice: return "waveform"
        case .tilt: return "gyroscope"
        case .auto: return "arrow.down.to.line"
        }
    }

    // MARK: Pieces

    private var header: some View {
        HStack {
            CircleButton(systemName: "xmark", label: "Close", action: onClose)
                .frame(width: 52, alignment: .leading)
            Spacer()
            // Tap the title to rename the script.
            Button {
                renaming = true
            } label: {
                HStack(spacing: 5) {
                    Text(engine.title)
                        .font(.headline)
                        .lineLimit(1)
                    Image(systemName: "pencil")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.primary)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Rename")
            .renameAlert(isPresented: $renaming, current: engine.title, onRename: onRename)
            Spacer()
            Text(engine.pointsLayout == .only ? "" : "\(engine.progressPercent)%")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
                .contentTransition(.numericText())
        }
        .padding(.top, 4)
    }

    private var status: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 9, height: 9)
                .scaleEffect(engine.hearing ? 1.35 : 1)
                .animation(.easeOut(duration: 0.2), value: engine.hearing)
            Text(statusText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
    }

    private var transport: some View {
        let pointsOnly = engine.pointsLayout == .only
        // Tilt levels itself in Voice mode; the button is only worth its space when tilt is the main control.
        let showsLevel = engine.mode == .tilt
        // Every button sits in the same 74 pt box, so all circles share a centre line
        // and all labels share a baseline.
        return HStack(alignment: .top, spacing: 0) {
            HStack(alignment: .top, spacing: 4) {
                if !pointsOnly {
                    ControlButton(systemName: "arrow.counterclockwise", title: "Restart") { engine.restart() }
                }
                ControlButton(systemName: "backward.fill", title: "Back") {
                    pointsOnly ? engine.previousPoint() : engine.backSentence()
                }
                ControlButton(systemName: "forward.fill", title: "Next") {
                    pointsOnly ? engine.nextPoint() : engine.nextSentence()
                }
                if showsLevel {
                    ControlButton(systemName: "level", title: "Level") { engine.recenterTilt() }
                }
            }

            Spacer(minLength: 8)

            Button {
                engine.togglePause()
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: engine.isPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(.black)
                        .frame(width: 74, height: 74)
                        .background(Color.white, in: Circle())
                        .contentTransition(.symbolEffect(.replace))
                    Text(engine.isPaused ? "Play" : "Pause")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .frame(width: Self.cornerWidth)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(engine.isPaused ? "Play" : "Pause")
        }
        .sensoryFeedback(.selection, trigger: engine.isPaused)
    }

    // MARK: Text

    private var statusColor: Color {
        if engine.problem != nil { return .orange }
        if engine.isPaused { return .gray }
        switch engine.mode {
        case .voice: return engine.hearing ? .green : .green.opacity(0.5)
        case .tilt, .auto: return .cueAccent
        }
    }

    private var statusText: String {
        if let p = engine.problem { return p }
        if !PiPController.isSupported { return "This iPhone can't float windows" }
        if engine.isFloating {
            return settings.shape == .upright ? "Floating · drag it under the camera" : "Floating · drag it to the camera side"
        }
        if engine.isPaused { return "Paused" }
        switch engine.mode {
        case .voice: return engine.hearing ? "Listening" : "Start talking — it follows you"
        case .tilt: return "Tip the phone to scroll"
        case .auto: return "\(Int(settings.autoSpeed)) words per minute"
        }
    }
}

private struct BarItem: View {
    let systemName: String
    let title: String

    var body: some View {
        VStack(spacing: 3) {
            // Same box for every symbol so icons and labels line up across the bar.
            Image(systemName: systemName)
                .font(.system(size: 20, weight: .medium))
                .frame(width: 30, height: 26)
            Text(title)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }
}

private extension View {
    /// One equal-width slot of the bottom bar, styled the same whether it's a button or a menu.
    func barSlot() -> some View {
        self
            .buttonStyle(.plain)
            .menuStyle(.button)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct CircleButton: View {
    let systemName: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(.white.opacity(0.14), in: Circle())
        }
        .accessibilityLabel(label)
    }
}

private struct ControlButton: View {
    let systemName: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemName)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(.white.opacity(0.13), in: Circle())
                    .frame(width: 60, height: 74)
                Text(title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}
