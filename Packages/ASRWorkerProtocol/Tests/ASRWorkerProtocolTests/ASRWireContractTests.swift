import Foundation
import Testing
@testable import ASRWorkerProtocol

@Suite("ASR worker wire contract")
struct ASRWireContractTests {
    /// Raw values are the wire itself: renumbering one silently breaks the
    /// framed protocol between an app and a worker built from different
    /// checkouts. This table only ever grows.
    @Test("wire kinds keep their raw values")
    func wireKindRawValuesAreStable() {
        #expect(ASRWireKind.hello.rawValue == 1)
        #expect(ASRWireKind.helloAcknowledged.rawValue == 2)
        #expect(ASRWireKind.prepareMain.rawValue == 3)
        #expect(ASRWireKind.prepareVocabulary.rawValue == 4)
        #expect(ASRWireKind.warmInference.rawValue == 5)
        #expect(ASRWireKind.transcribeSamples.rawValue == 6)
        #expect(ASRWireKind.transcribeFile.rawValue == 7)
        #expect(ASRWireKind.acknowledged.rawValue == 8)
        #expect(ASRWireKind.result.rawValue == 9)
        #expect(ASRWireKind.failure.rawValue == 10)
        #expect(ASRWireKind.shutdown.rawValue == 11)
        #expect(ASRWireKind.unloadModels.rawValue == 12)
    }

    @Test("version 2 is the unloadModels contract")
    func versionCoversUnloadModels() {
        #expect(ASRWorkerProtocol.version == 2)
    }
}
