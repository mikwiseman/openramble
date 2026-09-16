import SwiftUI

struct CommandLineToolSettings: View {
    @State private var link: URL?
    @State private var failure: String?

    var body: some View {
        Section {
            Button(link == nil ? "Install command-line tool" : "Reinstall command-line tool") {
                do {
                    link = try CommandLineToolInstaller.install()
                    failure = nil
                } catch {
                    failure = error.localizedDescription
                }
            }
            if let link {
                Text("Installed at \(link.path)")
                Text("Run: openramble audio.m4a")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                Text("If your terminal says 'command not found', add this line to your shell startup file, such as ~/.zshrc, then open a new terminal:")
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
            Text("Command line")
        } footer: {
            Text("Transcribe audio files using the installed model. Move OpenRamble to Applications before installing the command-line tool. Creates a link in ~/.local/bin; does not change your shell settings.")
        }
        .onAppear { link = CommandLineToolInstaller.installedLink() }
    }
}
