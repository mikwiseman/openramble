import Darwin
import Foundation
import Testing

@testable import AgentBridge

@Suite("Agent audio staging")
struct AudioFilePolicyTests {
    @Test("Staging rejects relative, non-regular, linked, empty, and oversized sources")
    func stagingRejectsUnsafeSources() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let address = try AgentBridgeSocketAddress(
            runtimeDirectory: root.appending(path: "bridge", directoryHint: .isDirectory)
        )
        try FileManager.default.createDirectory(
            at: address.stagingDirectory,
            withIntermediateDirectories: true
        )
        try AgentAudioStaging.prepareDirectory(address: address)

        let regular = root.appending(path: "voice.wav")
        try Data([1, 2, 3]).write(to: regular)
        let link = root.appending(path: "link.wav")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: regular)
        let empty = root.appending(path: "empty.wav")
        try Data().write(to: empty)

        #expect(throws: AudioFilePolicyError.pathMustBeAbsolute) {
            try AgentAudioStaging.stage(sourcePath: "voice.wav", address: address)
        }
        #expect(throws: AudioFilePolicyError.notARegularFile) {
            try AgentAudioStaging.stage(sourcePath: root.path, address: address)
        }
        #expect(throws: AudioFilePolicyError.symbolicLinksNotAllowed) {
            try AgentAudioStaging.stage(sourcePath: link.path, address: address)
        }
        #expect(throws: AudioFilePolicyError.empty) {
            try AgentAudioStaging.stage(sourcePath: empty.path, address: address)
        }
        #expect(throws: AudioFilePolicyError.tooLarge(actual: 3, maximum: 2)) {
            try AgentAudioStaging.stage(
                sourcePath: regular.path,
                address: address,
                maximumBytes: 2
            )
        }
    }

    @Test("Staging creates a private copy and accepts only generated basenames")
    func stagingRoundTrip() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "voice.wav")
        try Data([1, 2, 3, 4]).write(to: source)
        let address = try AgentBridgeSocketAddress(
            runtimeDirectory: root.appending(path: "bridge", directoryHint: .isDirectory)
        )
        try FileManager.default.createDirectory(
            at: address.stagingDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o777]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o777],
            ofItemAtPath: address.stagingDirectory.path
        )
        try AgentAudioStaging.prepareDirectory(address: address)
        let permissions = try FileManager.default.attributesOfItem(
            atPath: address.stagingDirectory.path
        )[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o700)

        let staged = try AgentAudioStaging.stage(sourcePath: source.path, address: address)
        defer { AgentAudioStaging.remove(name: staged.name, address: address) }

        #expect(staged.name.hasPrefix("audio-"))
        #expect(staged.byteCount == 4)
        #expect(try Data(contentsOf: staged.url) == Data([1, 2, 3, 4]))
        #expect(try AgentAudioStaging.validate(name: staged.name, address: address).byteCount == 4)
        #expect(throws: AgentAudioStagingError.invalidName) {
            try AgentAudioStaging.validate(name: "../voice.wav", address: address)
        }
        #expect(throws: AgentAudioStagingError.invalidName) {
            try AgentAudioStaging.validate(
                name: "audio-\(UUID().uuidString)\0.wav",
                address: address
            )
        }
        #expect(throws: AgentAudioStagingError.invalidName) {
            try AgentAudioStaging.validate(name: "audio-not-a-uuid.wav", address: address)
        }

        AgentAudioStaging.remove(name: staged.name, address: address)
        #expect(!FileManager.default.fileExists(atPath: staged.url.path))
    }

    private func temporaryDirectory() throws -> URL {
        let url = URL(
            fileURLWithPath: "/tmp/or-file-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
