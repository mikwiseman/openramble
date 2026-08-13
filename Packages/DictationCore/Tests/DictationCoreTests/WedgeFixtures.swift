/// Suspend forever and never resume — even under cancellation.
///
/// The closest honest model of a CoreML call stuck on a dead system
/// service: deaf to cancellation, holding no thread. The tempting
/// alternative — `while true { try? await Task.sleep(...) }` — models the
/// same wedge but turns into a hot spin the moment the watchdog cancels
/// it: on a cancelled task `Task.sleep` throws immediately, `try?`
/// swallows it, and the loop burns a cooperative-pool thread forever.
/// On a developer machine with many cores nobody notices; on a small CI
/// runner the leaked spinners starve the pool and hang every test after
/// them.
func suspendForever<T: Sendable>() async throws -> T {
    try await withUnsafeThrowingContinuation { (_: UnsafeContinuation<T, Error>) in }
}
