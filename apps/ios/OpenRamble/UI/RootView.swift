import SwiftUI

/// The model first, then the page of takes.
struct RootView: View {
    @Environment(ModelSetup.self) private var setup

    var body: some View {
        ZStack {
            if setup.isReady {
                HomeView()
                    .transition(.opacity)
            } else {
                SetupView()
                    .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.4), value: setup.isReady)
    }
}

/// The first screen: what OpenRamble is, and the one download it needs.
struct SetupView: View {
    @Environment(ModelSetup.self) private var setup

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 40)
            Text("Your words,\nwritten here.")
                .font(.system(size: 44, weight: .regular, design: .serif))
                .lineSpacing(2)
                .accessibilityAddTraits(.isHeader)
            Text("OpenRamble turns speech into text on this iPhone. Nothing you say is sent anywhere.")
                .font(.body)
                .foregroundStyle(.secondary)
                .padding(.top, 20)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 40)
            model
        }
        .padding(.horizontal, Theme.margin)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemBackground))
    }

    @ViewBuilder private var model: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch setup.phase {
            case .checking, .removing:
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 120)
            case .absent:
                about
                wide("Download") { setup.download() }
                    .padding(.top, 10)
            case let .downloading(received, total):
                about
                progress(Double(received) / Double(max(total, 1)))
                HStack {
                    Text(received == 0
                         ? "Starting…"
                         : "\(received.formatted(.byteCount(style: .file))) of \(total.formatted(.byteCount(style: .file)))")
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                    Spacer()
                    Button("Cancel") { setup.cancel() }
                        .font(.footnote)
                }
                Text("You can leave the app. The download carries on.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .verifying:
                about
                progress(1)
                Text("Checking every byte…")
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
            case let .failed(message):
                Text(message)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                wide("Try Again") { setup.download() }
                    .padding(.top, 10)
            case .ready:
                EmptyView()
            }
        }
        .animation(.smooth, value: setup.phase)
    }

    /// The one action, across the column, where the thumb is.
    private func wide(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.extraLarge)
    }

    private var about: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("First, the voice model")
                .font(.headline.weight(.regular))
            Text("Parakeet Ultra, \(setup.byteCount.formatted(.byteCount(style: .file))). Downloaded once; after that OpenRamble works offline.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func progress(_ fraction: Double) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(.primary)
                    .frame(width: max(4, geometry.size.width * min(1, fraction)))
            }
        }
        .frame(height: 3)
        .animation(.linear(duration: 0.2), value: fraction)
        .accessibilityElement()
        .accessibilityLabel("Download progress")
        .accessibilityValue("\(Int(fraction * 100)) percent")
    }
}
