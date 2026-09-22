import SwiftUI

/// The small, focused preflight for a screen take.
///
/// The screen is the hero. Capture choices are secondary tiles beneath it, so
/// the panel reads like a calm recorder rather than a settings form. The
/// controls are deliberately custom shaped: native switches are excellent in
/// Settings, but three identical switches inside a transient glass panel make
/// the most important choice hard to scan.
struct ScreenRecordingSetup: View {
    @ObservedObject var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.bottom, 18)
            preview
                .padding(.bottom, 18)
            captureControls
            footer
                .padding(.top, 20)
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 18)
        .frame(width: 560, height: 610)
        .glassWindowBackground()
        .task {
            if state.screenDisplays.isEmpty { await state.refreshScreenDisplays() }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.accentColor, Color.accentColor.opacity(0.62)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "rectangle.inset.filled")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 44, height: 44)
            .shadow(color: Color.accentColor.opacity(0.25), radius: 10, y: 4)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text("Capture your screen")
                    .font(.title3.weight(.semibold))
                Text("Choose what to include. You can move the camera bubble while recording.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Text("LOCAL")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(0.8)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.quaternary.opacity(0.55), in: Capsule())
                .overlay(Capsule().stroke(.primary.opacity(0.10), lineWidth: 0.5))
                .accessibilityLabel("Stored locally")
        }
    }

    private var preview: some View {
        ZStack(alignment: .topLeading) {
            previewCanvas

            if state.screenDisplays.count > 1 {
                Menu {
                    ForEach(state.screenDisplays) { display in
                        Button {
                            state.screenRecordingOptions.displayID = display.id
                        } label: {
                            if display.id == state.screenRecordingOptions.displayID {
                                Label(display.name, systemImage: "checkmark")
                            } else {
                                Text(display.name)
                            }
                        }
                    }
                } label: {
                    displayBadge
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .padding(12)
            } else {
                displayBadge
                    .padding(12)
            }

            if state.screenDisplays.isEmpty {
                permissionNotice
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(12)
            }

            if state.screenRecordingOptions.cameraEnabled {
                previewBubble
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(16)
                    .transition(.scale(scale: 0.7).combined(with: .opacity))
            }
        }
        .frame(height: 238)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.white.opacity(0.18), lineWidth: 0.75)
        }
        .shadow(color: .black.opacity(0.18), radius: 14, y: 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.screenDisplays.isEmpty ? "Screen preview unavailable" : "Preview of \(selectedDisplayName)")
    }

    private var previewCanvas: some View {
        GeometryReader { proxy in
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.05, green: 0.07, blue: 0.14),
                        Color(red: 0.12, green: 0.17, blue: 0.31),
                        Color(red: 0.07, green: 0.10, blue: 0.22),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                Circle()
                    .fill(Color.cyan.opacity(0.16))
                    .frame(width: proxy.size.width * 0.70)
                    .blur(radius: 24)
                    .offset(x: proxy.size.width * 0.30, y: -proxy.size.height * 0.30)
                Circle()
                    .fill(Color.purple.opacity(0.17))
                    .frame(width: proxy.size.width * 0.62)
                    .blur(radius: 30)
                    .offset(x: -proxy.size.width * 0.32, y: proxy.size.height * 0.35)

                VStack(spacing: 14) {
                    Image(systemName: "rectangle.inset.filled")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(.white.opacity(0.72))
                    Text(state.screenDisplays.isEmpty ? "Screen preview" : "Ready to record")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.white.opacity(0.75))
                }

                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.white.opacity(0.08))
                    .frame(width: proxy.size.width * 0.58, height: 72)
                    .offset(x: proxy.size.width * 0.12, y: -proxy.size.height * 0.18)
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.black.opacity(0.16))
                    .frame(width: proxy.size.width * 0.42, height: 50)
                    .offset(x: -proxy.size.width * 0.18, y: proxy.size.height * 0.22)
            }
        }
    }

    private var displayBadge: some View {
        HStack(spacing: 8) {
            Image(systemName: "display")
                .font(.caption.weight(.semibold))
            Text(selectedDisplayName)
                .font(.caption.weight(.medium))
                .lineLimit(1)
            if state.screenDisplays.count > 1 {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .opacity(0.7)
            }
        }
        .foregroundStyle(.white.opacity(0.88))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.black.opacity(0.34), in: Capsule())
    }

    private var previewBubble: some View {
        ZStack {
            Circle()
                .fill(.white.opacity(0.92))
            Circle()
                .stroke(.white, lineWidth: 2)
            Image(systemName: "person.fill")
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(Color.indigo.opacity(0.72))
        }
        .frame(width: previewBubbleSize, height: previewBubbleSize)
        .shadow(color: .black.opacity(0.32), radius: 9, y: 4)
        .accessibilityHidden(true)
    }

    private var captureControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Include")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(includeSummary)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 8) {
                CaptureOptionTile(
                    title: "Camera",
                    subtitle: "Bubble",
                    symbol: "video.fill",
                    isOn: state.screenRecordingOptions.cameraEnabled
                ) {
                    state.screenRecordingOptions.cameraEnabled.toggle()
                }
                CaptureOptionTile(
                    title: "Microphone",
                    subtitle: "Your voice",
                    symbol: "mic.fill",
                    isOn: state.screenRecordingOptions.microphoneEnabled
                ) {
                    state.screenRecordingOptions.microphoneEnabled.toggle()
                }
                CaptureOptionTile(
                    title: "Mac audio",
                    subtitle: "System sound",
                    symbol: "speaker.wave.2.fill",
                    isOn: state.screenRecordingOptions.systemAudioEnabled,
                    isDisabled: state.systemAudioMode == .unsupported
                ) {
                    state.screenRecordingOptions.systemAudioEnabled.toggle()
                }
            }

            HStack(spacing: 12) {
                if state.screenRecordingOptions.cameraEnabled {
                    HStack(spacing: 9) {
                        Image(systemName: "circle.dashed")
                            .foregroundStyle(Color.accentColor)
                        Text("Bubble size")
                            .font(.caption.weight(.medium))
                        Slider(value: $state.screenRecordingOptions.bubbleScale, in: 0.12...0.34)
                            .frame(maxWidth: .infinity)
                            .accessibilityLabel("Camera bubble size")
                        Text(sizeLabel)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 32, alignment: .trailing)
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                } else {
                    Label("Camera bubble is off", systemImage: "video.slash")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .frame(height: 24)
            .animation(reduceMotion ? nil : .easeOut(duration: GlassTokens.Motion.surfaceChange), value: state.screenRecordingOptions.cameraEnabled)
        }
    }

    private var footer: some View {
        HStack {
            Button("Cancel") { state.dismissScreenRecordingSetup() }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                state.startScreenRecording()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "record.circle.fill")
                    Text("Start recording")
                }
                .font(.body.weight(.semibold))
                .padding(.horizontal, 18)
                .frame(height: 38)
            }
            .buttonStyle(.borderedProminent)
            .tint(StatusColorRole.recording.color)
            .disabled(state.screenDisplays.isEmpty || state.isLoadingScreenDisplays)
            .keyboardShortcut(.defaultAction)
        }
    }

    private var permissionNotice: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.shield")
                .foregroundStyle(.orange)
            Text(permissionMessage)
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.88))
                .lineLimit(2)
            Spacer(minLength: 4)
            Button("Settings") { state.openScreenRecordingSettings() }
                .buttonStyle(.bordered)
                .controlSize(.small)
            Button("Retry") { Task { await state.refreshScreenDisplays() } }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.black.opacity(0.48), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private var selectedDisplayName: String {
        state.screenDisplays.first(where: { $0.id == state.screenRecordingOptions.displayID })?.name
            ?? state.screenDisplays.first?.name
            ?? "Choose a display"
    }

    private var includeSummary: String {
        let count = [
            state.screenRecordingOptions.cameraEnabled,
            state.screenRecordingOptions.microphoneEnabled,
            state.screenRecordingOptions.systemAudioEnabled,
        ].filter { $0 }.count
        return "\(count) of 3 selected"
    }

    private var previewBubbleSize: CGFloat {
        CGFloat(max(34, min(78, state.screenRecordingOptions.bubbleScale * 260)))
    }

    private var sizeLabel: String {
        "\(Int(state.screenRecordingOptions.bubbleScale * 100))%"
    }

    private var permissionMessage: String {
        let raw = state.screenSetupError?.lowercased() ?? ""
        if raw.contains("tcc") || raw.contains("declined") || raw.contains("permission") {
            return "Allow Screen Recording in System Settings"
        }
        return state.screenSetupError ?? "No display is available"
    }
}

private struct CaptureOptionTile: View {
    let title: String
    let subtitle: String
    let symbol: String
    let isOn: Bool
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .top) {
                    Image(systemName: symbol)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(isOn ? Color.accentColor : .secondary)
                    Spacer(minLength: 4)
                    Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(isOn ? Color.accentColor : .secondary.opacity(0.65))
                }
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 11)
            .padding(.vertical, 10)
            .background(
                isOn ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.045),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isOn ? Color.accentColor.opacity(0.42) : Color.primary.opacity(0.10), lineWidth: isOn ? 1 : 0.5)
            }
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.48 : 1)
        .accessibilityLabel("\(title), \(subtitle)")
        .accessibilityValue(isDisabled ? "Unavailable" : (isOn ? "On" : "Off"))
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// A compatibility spelling for call sites that prefer the explicit suffix.
typealias ScreenRecordingSetupView = ScreenRecordingSetup
