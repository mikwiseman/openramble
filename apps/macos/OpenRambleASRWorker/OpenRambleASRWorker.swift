import ASRWorkerProtocol
import Darwin
import Foundation

@main
struct OpenRambleASRWorker {
    static func main() async {
        do {
            try ASRWireIO.disableSIGPIPE(on: STDOUT_FILENO)
        } catch {
            Darwin._exit(EX_OSERR)
        }

        let runtime = ASRWorkerRuntime()
        let frames = AsyncStream<ASRWireFrame> { continuation in
            Thread.detachNewThread {
                do {
                    while let frame = try ASRWireIO.read(from: STDIN_FILENO) {
                        continuation.yield(frame)
                    }
                    // Parent pipe EOF is a process-lifetime command, including
                    // while another task is stuck inside Core ML.
                    Darwin._exit(EXIT_SUCCESS)
                } catch {
                    Darwin._exit(EX_PROTOCOL)
                }
            }
        }

        for await frame in frames {
            guard await runtime.handle(frame) else { Darwin._exit(EXIT_SUCCESS) }
        }
        Darwin._exit(EXIT_SUCCESS)
    }
}
