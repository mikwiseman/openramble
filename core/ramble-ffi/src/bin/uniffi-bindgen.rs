//! Generates the Swift bindings for `ramble-ffi`.
//!
//! Run by `scripts/build-ffi.sh`. Kept as an explicit binary rather than a build
//! script so producing Swift is a step somebody chose to take and can inspect
//! the output of, not a side effect of an ordinary build.
fn main() {
    uniffi::uniffi_bindgen_main()
}
