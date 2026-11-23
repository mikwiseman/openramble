import SwiftUI

/// The few things there are to decide, and what the app promises.
struct SettingsView: View {
    @Environment(Dictation.self) private var dictation
    @Environment(ModelSetup.self) private var setup
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var confirmsRemoval = false

    var body: some View {
        @Bindable var dictation = dictation
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    row {
                        Toggle(isOn: $dictation.copiesEachTake) {
                            Text("Copy each take")
                        }
                        .tint(.primary)
                        note("The words are ready to paste the moment they are written. They stay on this iPhone and are not shared with your other devices.")
                    }
                    row {
                        Text("Voice model")
                        note("Parakeet Ultra, \(setup.byteCount.formatted(.byteCount(style: .file))). It runs on this iPhone's processor with OpenRamble's own engine, so it works without a connection.")
                        Button("Remove Voice Model", role: .destructive) { confirmsRemoval = true }
                            .font(.callout)
                            .padding(.top, 6)
                    }
                    row {
                        Text("Privacy")
                        note("Nothing you say leaves this iPhone. Takes, their recordings and the model are kept in this app only, are not part of iCloud Backup, and are gone when you delete them or the app. The app goes online once, to download the model.")
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("OpenRamble \(Self.version) · MIT License")
                        Link("Source code", destination: URL(string: "https://github.com/mikwiseman/openramble")!)
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.top, 28)
                }
                .padding(.horizontal, Theme.margin)
                .padding(.bottom, 32)
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
            .confirmationDialog("Remove the voice model?", isPresented: $confirmsRemoval, titleVisibility: .visible) {
                Button("Remove", role: .destructive) {
                    Task {
                        await setup.remove()
                        dismiss()
                    }
                }
            } message: {
                Text("Your takes stay. To write new ones, the model is downloaded again.")
            }
        }
        .presentationDetents([.large])
    }

    /// A row is air and a hairline, never a box.
    private func row(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 22)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(.primary.opacity(GlassTokens.Stroke.opacity(increasedContrast: contrast == .increased)))
                .frame(height: GlassTokens.Stroke.hairline)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }
}
