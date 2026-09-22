import Foundation

/// The two sides of a conversation, as the two channels of one file.
///
/// A meeting is recorded from two physically separate streams — the microphone
/// hears the person at the Mac, the system output carries everyone else — and
/// that separation is the whole speaker story. Nothing has to guess who spoke:
/// the channel is the label. A voice note is a meeting with one participant,
/// and it uses the same file with the second channel silent, so the format
/// never changes underneath a recording.
public enum MeetingChannel: String, Codable, Sendable, CaseIterable, Hashable {
    case microphone
    case system
}

/// The media captured by a recording. Audio is the historical OpenRamble
/// recording format; screen adds a local video alongside the same WAV.
public enum RecordingCaptureKind: String, Codable, Sendable, Equatable {
    case audio
    case screen
}

/// A point expressed as a fraction of the captured display (0...1 after
/// clamping by the UI). Keeping the value independent of pixels means a
/// camera bubble can be restored on a Retina display or a different scale.
public struct NormalizedPoint: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// Settings captured with a screen recording. These are recording metadata,
/// rather than a persistent account or cloud setting.
public struct ScreenRecordingOptions: Codable, Sendable, Equatable {
    public var displayID: UInt32?
    public var cameraEnabled: Bool
    public var microphoneEnabled: Bool
    public var systemAudioEnabled: Bool
    public var bubbleScale: Double
    public var bubblePosition: NormalizedPoint

    public init(
        displayID: UInt32? = nil,
        cameraEnabled: Bool = false,
        microphoneEnabled: Bool = true,
        systemAudioEnabled: Bool = false,
        bubbleScale: Double = 0.20,
        bubblePosition: NormalizedPoint = NormalizedPoint(x: 0.15, y: 0.82)
    ) {
        self.displayID = displayID
        self.cameraEnabled = cameraEnabled
        self.microphoneEnabled = microphoneEnabled
        self.systemAudioEnabled = systemAudioEnabled
        self.bubbleScale = bubbleScale
        self.bubblePosition = bubblePosition
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            displayID: try c.decodeIfPresent(UInt32.self, forKey: .displayID),
            cameraEnabled: try c.decodeIfPresent(Bool.self, forKey: .cameraEnabled) ?? false,
            microphoneEnabled: try c.decodeIfPresent(Bool.self, forKey: .microphoneEnabled) ?? true,
            systemAudioEnabled: try c.decodeIfPresent(Bool.self, forKey: .systemAudioEnabled) ?? false,
            bubbleScale: try c.decodeIfPresent(Double.self, forKey: .bubbleScale) ?? 0.20,
            bubblePosition: try c.decodeIfPresent(NormalizedPoint.self, forKey: .bubblePosition)
                ?? NormalizedPoint(x: 0.15, y: 0.82)
        )
    }
}

/// A span on the recording's own timeline, in seconds.
public struct MeetingInterval: Codable, Sendable, Equatable {
    public var start: TimeInterval
    public var end: TimeInterval

    public init(start: TimeInterval, end: TimeInterval) {
        self.start = start
        self.end = end
    }
}

/// A stretch where one channel carried no audio and was filled with silence.
///
/// Recorded rather than hidden: a transcript with a hole in it should be able
/// to say why, and "the other side went quiet at 12:04 because the output
/// device changed" is an answer, where an unexplained gap is a bug report.
public struct MeetingGap: Codable, Sendable, Equatable {
    public enum Reason: String, Codable, Sendable {
        case systemAudioStalled
        case systemAudioRouteChange
        case microphoneUnavailable
        case clockUnavailable
    }

    public var channel: MeetingChannel
    public var start: TimeInterval
    public var end: TimeInterval
    public var reason: Reason

    public init(channel: MeetingChannel, start: TimeInterval, end: TimeInterval, reason: Reason) {
        self.channel = channel
        self.start = start
        self.end = end
        self.reason = reason
    }
}

/// How a recording came to an end. `nil` on the metadata means it has not.
public enum MeetingEndReason: String, Codable, Sendable {
    case stoppedByUser
    case diskFull
    case writeFailed
    case applicationQuit
    /// The app died mid-recording and the file was repaired on the next launch.
    case crashRecovered
}

public enum MeetingTranscriptionState: String, Codable, Sendable {
    /// Never attempted.
    case none
    case live
    case complete
    case partial
    case failed
    case waitingForModel
}

/// What happened on the system-audio side, kept so a one-sided recording can
/// explain itself later.
///
/// `outputTransport` (built-in, bluetooth, airplay, usb…) is the single most
/// useful fact when someone reports "the other side is missing": a tap on a
/// Bluetooth route can be granted and healthy and still hear nothing. A
/// transport type is not user content.
public struct SystemAudioSummary: Codable, Sendable, Equatable {
    public var wasRequested: Bool
    public var everDeliveredBuffers: Bool
    public var everDeliveredAudio: Bool
    public var outputTransport: String?

    public init(
        wasRequested: Bool,
        everDeliveredBuffers: Bool = false,
        everDeliveredAudio: Bool = false,
        outputTransport: String? = nil
    ) {
        self.wasRequested = wasRequested
        self.everDeliveredBuffers = everDeliveredBuffers
        self.everDeliveredAudio = everDeliveredAudio
        self.outputTransport = outputTransport
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        wasRequested = try container.decodeIfPresent(Bool.self, forKey: .wasRequested) ?? false
        everDeliveredBuffers = try container.decodeIfPresent(Bool.self, forKey: .everDeliveredBuffers) ?? false
        everDeliveredAudio = try container.decodeIfPresent(Bool.self, forKey: .everDeliveredAudio) ?? false
        outputTransport = try container.decodeIfPresent(String.self, forKey: .outputTransport)
    }
}

/// One recording, as `meta.json` beside its audio.
///
/// Every optional here decodes with a default from the first commit, on
/// purpose. `HistoryEntry` had to grow that retroactively when a field was
/// added, and a store that refuses its own older files loses exactly the
/// recordings it exists to keep.
public struct MeetingRecordingMetadata: Codable, Sendable, Equatable, Identifiable {
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    public var id: UUID
    public var startedAt: Date
    /// Recorded seconds — pauses excluded — so it matches the audio file.
    public var duration: TimeInterval
    /// Given by the person. Absent, the date stands in; a title is never
    /// invented from the first words, or the library reads "um can everyone
    /// hear me" forever.
    public var title: String?
    public var sampleRate: Int
    /// Index equals the channel's index in the WAV.
    public var channelLayout: [MeetingChannel]
    public var microphoneDeviceName: String?
    /// `nil` on recordings filed before this was stored: unknown, not missing.
    /// `false` means the microphone channel was silence for the whole take.
    public var microphoneEverDeliveredAudio: Bool?
    public var systemAudio: SystemAudioSummary
    public var pauses: [MeetingInterval]
    public var gaps: [MeetingGap]
    /// `nil` while the recording is still running.
    public var endReason: MeetingEndReason?
    public var transcriptionState: MeetingTranscriptionState
    /// Absent from old files, which are audio recordings.
    public var captureKind: RecordingCaptureKind
    public var videoFileName: String?
    public var screenOptions: ScreenRecordingOptions?
    public var displayName: String?

    public init(
        id: UUID = UUID(),
        startedAt: Date,
        duration: TimeInterval = 0,
        title: String? = nil,
        sampleRate: Int = 16_000,
        channelLayout: [MeetingChannel] = [.microphone, .system],
        microphoneDeviceName: String? = nil,
        microphoneEverDeliveredAudio: Bool? = nil,
        systemAudio: SystemAudioSummary,
        pauses: [MeetingInterval] = [],
        gaps: [MeetingGap] = [],
        endReason: MeetingEndReason? = nil,
        transcriptionState: MeetingTranscriptionState = .none,
        captureKind: RecordingCaptureKind = .audio,
        videoFileName: String? = nil,
        screenOptions: ScreenRecordingOptions? = nil,
        displayName: String? = nil
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.startedAt = startedAt
        self.duration = duration
        self.title = title
        self.sampleRate = sampleRate
        self.channelLayout = channelLayout
        self.microphoneDeviceName = microphoneDeviceName
        self.microphoneEverDeliveredAudio = microphoneEverDeliveredAudio
        self.systemAudio = systemAudio
        self.pauses = pauses
        self.gaps = gaps
        self.endReason = endReason
        self.transcriptionState = transcriptionState
        self.captureKind = captureKind
        self.videoFileName = videoFileName
        self.screenOptions = screenOptions
        self.displayName = displayName
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        id = try c.decode(UUID.self, forKey: .id)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        duration = try c.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 0
        title = try c.decodeIfPresent(String.self, forKey: .title)
        sampleRate = try c.decodeIfPresent(Int.self, forKey: .sampleRate) ?? 16_000
        channelLayout = try c.decodeIfPresent([MeetingChannel].self, forKey: .channelLayout)
            ?? [.microphone, .system]
        microphoneDeviceName = try c.decodeIfPresent(String.self, forKey: .microphoneDeviceName)
        microphoneEverDeliveredAudio = try c.decodeIfPresent(Bool.self, forKey: .microphoneEverDeliveredAudio)
        systemAudio = try c.decodeIfPresent(SystemAudioSummary.self, forKey: .systemAudio)
            ?? SystemAudioSummary(wasRequested: false)
        pauses = try c.decodeIfPresent([MeetingInterval].self, forKey: .pauses) ?? []
        gaps = try c.decodeIfPresent([MeetingGap].self, forKey: .gaps) ?? []
        endReason = try c.decodeIfPresent(MeetingEndReason.self, forKey: .endReason)
        transcriptionState = try c.decodeIfPresent(MeetingTranscriptionState.self, forKey: .transcriptionState)
            ?? .none
        captureKind = try c.decodeIfPresent(RecordingCaptureKind.self, forKey: .captureKind) ?? .audio
        videoFileName = try c.decodeIfPresent(String.self, forKey: .videoFileName)
        screenOptions = try c.decodeIfPresent(ScreenRecordingOptions.self, forKey: .screenOptions)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
    }

    /// Whether the other side was ever listened to. A voice note has one
    /// channel by choice; a meeting recorded with a silent tap has two by
    /// accident, and the two must never look the same.
    public var isMeeting: Bool { systemAudio.wasRequested }
}

/// A stretch of one channel, by position in the file — never a copy of the
/// audio. Twenty-four bytes, however long the stretch: the frames are already
/// on disk, and whoever decodes this reads them back when its turn comes.
public struct MeetingSegmentRef: Sendable, Equatable, Hashable, Codable {
    public let channel: MeetingChannel
    public let startFrame: Int
    public let frameCount: Int

    public init(channel: MeetingChannel, startFrame: Int, frameCount: Int) {
        self.channel = channel
        self.startFrame = startFrame
        self.frameCount = frameCount
    }

    public var endFrame: Int { startFrame + frameCount }
}

/// One paragraph of transcript, attributed by channel.
///
/// Start and end come from where the audio was cut, on the recording's own
/// timeline, so a line can be clicked to play from — no engine timestamps are
/// needed for that.
public struct MeetingUtterance: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var channel: MeetingChannel
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String
    /// The decode of this stretch failed. The audio is intact; it can be tried
    /// again, and until then the transcript says so rather than skipping it.
    public var isFailed: Bool

    public init(
        id: UUID = UUID(),
        channel: MeetingChannel,
        start: TimeInterval,
        end: TimeInterval,
        text: String,
        isFailed: Bool = false
    ) {
        self.id = id
        self.channel = channel
        self.start = start
        self.end = end
        self.text = text
        self.isFailed = isFailed
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        channel = try c.decode(MeetingChannel.self, forKey: .channel)
        start = try c.decode(TimeInterval.self, forKey: .start)
        end = try c.decode(TimeInterval.self, forKey: .end)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        isFailed = try c.decodeIfPresent(Bool.self, forKey: .isFailed) ?? false
    }
}

/// `transcript.json`: the utterances so far, and how far each channel has been
/// decoded — the resumption point after a crash or a relaunch.
public struct MeetingTranscript: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var utterances: [MeetingUtterance]
    public var decodedFrames: [MeetingChannel: Int]

    public init(utterances: [MeetingUtterance] = [], decodedFrames: [MeetingChannel: Int] = [:]) {
        schemaVersion = Self.currentSchemaVersion
        self.utterances = utterances
        self.decodedFrames = decodedFrames
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        utterances = try c.decodeIfPresent([MeetingUtterance].self, forKey: .utterances) ?? []
        decodedFrames = try c.decodeIfPresent([MeetingChannel: Int].self, forKey: .decodedFrames) ?? [:]
    }
}

/// The one way these files are written and read.
///
/// The date strategy is pinned on both sides. `DictationHistoryStore.write`
/// records the incident this guards against: an encoder configured for one
/// strategy against a decoder using another read a whole history back as
/// empty, with no error anywhere. ISO-8601 is chosen over the Foundation
/// default because a person opening `meta.json` can read it.
public enum MeetingRecordingCoding {
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
