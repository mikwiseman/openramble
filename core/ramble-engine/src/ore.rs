//! The C boundary of the engine in `engine/`, and the only unsafe code in
//! this crate. `build.rs` compiles the engine; this file calls it.
//!
//! The declarations mirror `engine/include/ore.h`. A session's results are
//! copied into owned values before the call that produced them returns,
//! because the engine clears them at the start of the next run.

use std::ffi::{c_char, c_int, CStr, CString};
use std::path::Path;

#[repr(C)]
struct RawModel {
    _opaque: [u8; 0],
}

#[repr(C)]
struct RawSession {
    _opaque: [u8; 0],
}

#[repr(C)]
struct RawWord {
    text: *const c_char,
    t0_ms: i64,
    t1_ms: i64,
}

const ORE_OK: c_int = 0;
const ORE_ERR_MEMORY: c_int = 2;
const ORE_ERR_ABORTED: c_int = 3;

extern "C" {
    fn ore_version() -> *const c_char;
    fn ore_model_open(path: *const c_char, error: *mut *const c_char) -> *mut RawModel;
    fn ore_model_close(model: *mut RawModel);
    fn ore_session_open(model: *const RawModel, threads: c_int) -> *mut RawSession;
    fn ore_session_close(session: *mut RawSession);
    fn ore_run(session: *mut RawSession, samples: *const f32, n_samples: c_int) -> c_int;
    fn ore_text(session: *const RawSession) -> *const c_char;
    fn ore_word_count(session: *const RawSession) -> c_int;
    fn ore_word_at(session: *const RawSession, index: c_int, out: *mut RawWord) -> c_int;
    fn ore_session_kernels(session: *const RawSession) -> *const c_char;
    fn ore_processor_kernels() -> *const c_char;
    fn ore_session_threads(session: *const RawSession) -> c_int;
}

/// A word as the engine gives it: untrimmed, with times that may lie outside
/// the clip.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub(crate) struct Word {
    pub text: String,
    pub t0_ms: i64,
    pub t1_ms: i64,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub(crate) struct Heard {
    pub text: String,
    pub words: Vec<Word>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Failure {
    Aborted,
    Other(&'static str),
}

/// The engine's version, as its header states it.
pub(crate) fn version() -> String {
    // SAFETY: the engine returns a static NUL-terminated string.
    unsafe { owned(ore_version()) }
}

/// The kernel set a session on this processor will use, known without a
/// model.
pub(crate) fn processor_kernels() -> String {
    // SAFETY: the engine returns a static NUL-terminated string.
    unsafe { owned(ore_processor_kernels()) }
}

/// One opened model and the one session that runs on it.
pub(crate) struct Recognizer {
    model: *mut RawModel,
    session: *mut RawSession,
}

// SAFETY: a session is not tied to the thread that opened it. It keeps its
// own worker threads and touches no thread-local state. `&mut self` on `run`
// keeps two threads out of one session at once.
unsafe impl Send for Recognizer {}

impl Recognizer {
    /// Open a model file. `threads` of 0 lets the engine choose: the number
    /// of processors, at most four.
    pub(crate) fn open(path: &Path, threads: usize) -> Result<Self, String> {
        let c_path = c_path(path).ok_or("the model path cannot be passed to the engine")?;
        let mut error: *const c_char = std::ptr::null();
        // SAFETY: `c_path` is NUL-terminated and outlives the call; `error`
        // is a valid place for the engine's static message.
        let model = unsafe { ore_model_open(c_path.as_ptr(), &mut error) };
        if model.is_null() {
            // SAFETY: on failure the engine leaves a static string or NULL.
            let detail = unsafe { owned(error) };
            return Err(if detail.is_empty() {
                "the model file could not be opened".into()
            } else {
                detail
            });
        }
        let threads = c_int::try_from(threads).unwrap_or(0);
        // SAFETY: `model` was just opened and is not shared.
        let session = unsafe { ore_session_open(model, threads) };
        if session.is_null() {
            // SAFETY: no session refers to the model.
            unsafe { ore_model_close(model) };
            return Err("not enough memory to start the recognizer".into());
        }
        Ok(Recognizer { model, session })
    }

    /// Recognize 16 kHz mono audio.
    pub(crate) fn run(&mut self, samples: &[f32]) -> Result<Heard, Failure> {
        let n_samples = c_int::try_from(samples.len())
            .map_err(|_| Failure::Other("the clip is too long for one run"))?;
        // SAFETY: the session is open, and the pointer and length describe
        // `samples`, which the engine only reads during the call.
        let status = unsafe { ore_run(self.session, samples.as_ptr(), n_samples) };
        match status {
            ORE_OK => {}
            ORE_ERR_ABORTED => return Err(Failure::Aborted),
            ORE_ERR_MEMORY => return Err(Failure::Other("not enough memory")),
            _ => return Err(Failure::Other("the model cannot take this clip")),
        }
        // SAFETY: the run succeeded, so the session holds a result until the
        // next run; everything is copied out before `self` can be used again.
        unsafe {
            let count = ore_word_count(self.session);
            let mut words = Vec::with_capacity(usize::try_from(count).unwrap_or(0));
            for index in 0..count {
                let mut word = RawWord {
                    text: std::ptr::null(),
                    t0_ms: 0,
                    t1_ms: 0,
                };
                if ore_word_at(self.session, index, &mut word) != 0 {
                    words.push(Word {
                        text: owned(word.text),
                        t0_ms: word.t0_ms,
                        t1_ms: word.t1_ms,
                    });
                }
            }
            Ok(Heard {
                text: owned(ore_text(self.session)),
                words,
            })
        }
    }

    /// The kernel set the engine chose for this processor: "avx2", "neon",
    /// "sse" and so on.
    pub(crate) fn kernels(&self) -> String {
        // SAFETY: the session is open; the name is a static string.
        unsafe { owned(ore_session_kernels(self.session)) }
    }

    pub(crate) fn threads(&self) -> usize {
        // SAFETY: the session is open.
        usize::try_from(unsafe { ore_session_threads(self.session) }).unwrap_or(1)
    }
}

impl Drop for Recognizer {
    fn drop(&mut self) {
        // SAFETY: both were opened in `open` and are closed once, the
        // session before the model it reads.
        unsafe {
            ore_session_close(self.session);
            ore_model_close(self.model);
        }
    }
}

/// A copy of a C string, or the empty string for NULL.
///
/// # Safety
/// `text` is NULL or points at a NUL-terminated string that stays valid for
/// the call.
unsafe fn owned(text: *const c_char) -> String {
    if text.is_null() {
        return String::new();
    }
    CStr::from_ptr(text).to_string_lossy().into_owned()
}

/// The path as the engine wants it: the raw bytes on Unix, UTF-8 on Windows,
/// where the engine converts it to a wide path itself.
fn c_path(path: &Path) -> Option<CString> {
    #[cfg(unix)]
    {
        use std::os::unix::ffi::OsStrExt;
        CString::new(path.as_os_str().as_bytes()).ok()
    }
    #[cfg(not(unix))]
    {
        CString::new(path.to_str()?).ok()
    }
}
