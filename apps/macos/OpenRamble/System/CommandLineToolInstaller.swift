import Foundation

enum CommandLineToolInstaller {
    enum Failure: LocalizedError {
        case missingExecutable
        case unstableLocation
        case destinationExists(String)

        var errorDescription: String? {
            switch self {
            case .missingExecutable:
                return "This copy of OpenRamble does not contain the command-line tool."
            case .unstableLocation:
                return "Move OpenRamble to Applications first: the link would point at a location that disappears."
            case let .destinationExists(path):
                return "Something else already exists at \(path). Move or remove it before installing the command-line tool."
            }
        }
    }

    private static let executableSuffix = "Contents/MacOS/openramble-cli"
    private static let linkPath = ".local/bin/openramble"

    private static func executable(in bundleURL: URL) -> URL {
        // Bundle.main.bundleURL carries a trailing slash; appending a leading
        // slash would yield "//" and defeat the path comparisons below.
        bundleURL.appendingPathComponent(executableSuffix).standardizedFileURL
    }

    /// The link if it exists and points at this app's executable.
    static func installedLink(
        bundleURL: URL = Bundle.main.bundleURL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL? {
        let link = homeDirectory.appendingPathComponent(linkPath)
        let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)
        return destination == executable(in: bundleURL).path ? link : nil
    }

    /// Called only by the settings button. Never changes shell startup files.
    /// Replaces a link left by an earlier copy of this app; refuses anything else.
    static func install(
        bundleURL: URL = Bundle.main.bundleURL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> URL {
        // A mounted DMG or Gatekeeper's translocated copy is gone after relaunch.
        guard !bundleURL.path.hasPrefix("/Volumes/"),
              !bundleURL.path.contains("/AppTranslocation/") else {
            throw Failure.unstableLocation
        }
        let manager = FileManager.default
        let executable = executable(in: bundleURL)
        guard manager.isExecutableFile(atPath: executable.path) else {
            throw Failure.missingExecutable
        }
        let link = homeDirectory.appendingPathComponent(linkPath)
        if let destination = try? manager.destinationOfSymbolicLink(atPath: link.path) {
            if destination == executable.path { return link }
            guard destination.hasSuffix("/" + executableSuffix) else {
                throw Failure.destinationExists(link.path)
            }
            try manager.removeItem(at: link)
        } else if manager.fileExists(atPath: link.path) {
            throw Failure.destinationExists(link.path)
        }
        try manager.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manager.createSymbolicLink(at: link, withDestinationURL: executable)
        return link
    }
}
