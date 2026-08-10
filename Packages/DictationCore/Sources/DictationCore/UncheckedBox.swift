/// Wrapper for values that the compiler considers unsafe to pass
/// between threads, although in fact they are used in one.
///
/// Needed for audio APIs: `AVAudioConverter.convert` accepts a closure,
/// marked as parallel, but calls it synchronously on the same thread as
/// and the call itself. Without a wrapper, the compiler prohibits passing a buffer there, and
/// disabling checks throughout the file means losing them where they are useful.
public final class UncheckedBox<Value>: @unchecked Sendable {
    public var value: Value

    public init(_ value: Value) {
        self.value = value
    }
}
