import SwiftUI

struct CommandLineToolSettings: View {
    @State private var link: URL?
    @State private var failure: String?

    var body: some View {
        Section {
            Button(link == nil ? L10n.tr("Install command-line tool") : L10n.tr("Reinstall command-line tool")) {
                do {
                    link = try CommandLineToolInstaller.install()
                    failure = nil
                } catch {
                    failure = error.localizedDescription
                }
            }
            if let link {
                Text(L10n.tr("Installed at %@", String(describing: link.path)))
                Text(L10n.tr("Run: openramble audio.m4a"))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                Text(L10n.tr("If your terminal says 'command not found', add this line to your shell startup file, such as ~/.zshrc, then open a new terminal:"))
                    .font(.caption)
                Text("export PATH=\"$HOME/.local/bin:$PATH\"")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
            if let failure {
                Text(failure)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        } header: {
            Text(L10n.tr("Command line"))
        } footer: {
            Text(L10n.tr("Transcribe audio files using the installed model. Move OpenRamble to Applications before installing the command-line tool. Creates a link in ~/.local/bin; does not change your shell settings."))
        }
        .onAppear { link = CommandLineToolInstaller.installedLink() }
    }
}
