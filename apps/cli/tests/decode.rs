//! ffmpeg decoding against real files, generated with ffmpeg itself.
//!
//! Skipped on a machine without ffmpeg, since that is a missing tool rather
//! than a defect here. CI's Linux server job installs it.

use std::fs::File;
use std::io::{Seek, SeekFrom, Write};
use std::os::unix::fs::FileExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use openramble_cli::decode::{decode, DecodeError, Decoded};

fn ffmpeg() -> bool {
    let found = Command::new("ffmpeg")
        .arg("-version")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .is_ok_and(|status| status.success());
    if !found {
        eprintln!("no ffmpeg; skipping");
    }
    found
}

/// Run ffmpeg to make a test file; true when it could.
fn make(out: &Path, args: &[&str]) -> bool {
    Command::new("ffmpeg")
        .args(["-v", "error", "-y"])
        .args(args)
        .arg(out)
        .stdin(Stdio::null())
        .status()
        .is_ok_and(|status| status.success())
}

const TONE: [&str; 4] = ["-f", "lavfi", "-i", "sine=frequency=440:duration=3"];

fn run(path: &Path, temp: &Path, max_s: f64) -> Result<Decoded, DecodeError> {
    let decoded = decode(File::open(path).unwrap(), temp, max_s, &|| false);
    assert_eq!(
        listing(temp),
        Vec::<PathBuf>::new(),
        "a file was left behind"
    );
    decoded
}

fn listing(directory: &Path) -> Vec<PathBuf> {
    let mut names: Vec<PathBuf> = std::fs::read_dir(directory)
        .unwrap()
        .map(|entry| entry.unwrap().path())
        .collect();
    names.sort();
    names
}

/// About three seconds of the 440 Hz tone at lavfi's default level.
fn assert_tone(decoded: &Decoded) {
    assert!(
        (46_000..=50_000).contains(&decoded.samples),
        "{} samples",
        decoded.samples
    );
    assert_eq!(decoded.envelope.len() as u64, decoded.samples.div_ceil(320));
    let middle = decoded.envelope[decoded.envelope.len() / 2];
    assert!((0.07..0.11).contains(&middle), "rms {middle}");
    assert_eq!(decoded.pcm.metadata().unwrap().len(), decoded.samples * 4);
    let mut sample = [0u8; 4];
    decoded.pcm.read_exact_at(&mut sample, 20_000 * 4).unwrap();
    assert!(f32::from_le_bytes(sample).abs() <= 0.2);
}

#[test]
fn an_m4a_with_its_index_at_the_end_decodes() {
    if !ffmpeg() {
        return;
    }
    let files = tempfile::tempdir().unwrap();
    let temp = tempfile::tempdir().unwrap();
    let m4a = files.path().join("tone.m4a");
    // The mp4 muxer writes the index last unless told +faststart.
    assert!(make(&m4a, &[&TONE[..], &["-c:a", "aac"]].concat()));
    assert_tone(&run(&m4a, temp.path(), 60.0).unwrap());
}

#[test]
fn ogg_opus_decodes() {
    if !ffmpeg() {
        return;
    }
    let files = tempfile::tempdir().unwrap();
    let temp = tempfile::tempdir().unwrap();
    let oga = files.path().join("voice.oga");
    assert!(
        make(&oga, &[&TONE[..], &["-c:a", "libopus"]].concat())
            || make(
                &oga,
                &[
                    &TONE[..],
                    &["-c:a", "opus", "-strict", "-2", "-ar", "48000"]
                ]
                .concat()
            )
    );
    assert_tone(&run(&oga, temp.path(), 60.0).unwrap());
}

#[test]
fn a_video_with_sound_decodes_to_its_sound() {
    if !ffmpeg() {
        return;
    }
    let files = tempfile::tempdir().unwrap();
    let temp = tempfile::tempdir().unwrap();
    let mp4 = files.path().join("note.mp4");
    assert!(make(
        &mp4,
        &[
            "-f",
            "lavfi",
            "-i",
            "testsrc=size=64x64:rate=10:duration=3",
            "-f",
            "lavfi",
            "-i",
            "sine=frequency=440:duration=3",
            "-c:v",
            "mpeg4",
            "-c:a",
            "aac",
        ]
    ));
    assert_tone(&run(&mp4, temp.path(), 60.0).unwrap());
}

#[test]
fn garbage_and_silent_video_are_invalid_audio() {
    if !ffmpeg() {
        return;
    }
    let files = tempfile::tempdir().unwrap();
    let temp = tempfile::tempdir().unwrap();

    let garbage = files.path().join("garbage.bin");
    let noise: Vec<u8> = (0..100_000u32)
        .map(|i| (i.wrapping_mul(2_654_435_761) >> 13) as u8)
        .collect();
    std::fs::write(&garbage, noise).unwrap();
    assert!(matches!(
        run(&garbage, temp.path(), 60.0),
        Err(DecodeError::InvalidAudio)
    ));

    let empty = files.path().join("empty.m4a");
    std::fs::write(&empty, b"").unwrap();
    assert!(matches!(
        run(&empty, temp.path(), 60.0),
        Err(DecodeError::InvalidAudio)
    ));

    let video = files.path().join("video.mp4");
    assert!(make(
        &video,
        &[
            "-f",
            "lavfi",
            "-i",
            "testsrc=size=64x64:rate=10:duration=2",
            "-c:v",
            "mpeg4",
        ]
    ));
    assert!(matches!(
        run(&video, temp.path(), 60.0),
        Err(DecodeError::InvalidAudio)
    ));
}

#[test]
fn a_playlist_pointing_at_the_network_is_refused_without_a_connection() {
    if !ffmpeg() {
        return;
    }
    let files = tempfile::tempdir().unwrap();
    let temp = tempfile::tempdir().unwrap();
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    listener.set_nonblocking(true).unwrap();
    let port = listener.local_addr().unwrap().port();
    let playlist = files.path().join("list.m3u8");
    std::fs::write(
        &playlist,
        format!(
            "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:10\n#EXTINF:10.0,\n\
             http://127.0.0.1:{port}/segment.ts\n#EXT-X-ENDLIST\n"
        ),
    )
    .unwrap();
    assert!(matches!(
        run(&playlist, temp.path(), 60.0),
        Err(DecodeError::InvalidAudio)
    ));
    match listener.accept() {
        Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {}
        other => panic!("ffmpeg reached the network: {other:?}"),
    }
}

#[test]
fn audio_past_the_cap_is_too_long() {
    if !ffmpeg() {
        return;
    }
    let files = tempfile::tempdir().unwrap();
    let temp = tempfile::tempdir().unwrap();
    let wav = files.path().join("long.wav");
    assert!(make(
        &wav,
        &["-f", "lavfi", "-i", "sine=duration=600", "-ar", "16000"]
    ));
    let started = std::time::Instant::now();
    assert!(matches!(
        run(&wav, temp.path(), 2.0),
        Err(DecodeError::TooLong)
    ));
    assert!(started.elapsed().as_secs() < 5);
}

#[test]
fn a_hang_up_cancels_and_leaves_nothing() {
    if !ffmpeg() {
        return;
    }
    let files = tempfile::tempdir().unwrap();
    let temp = tempfile::tempdir().unwrap();
    let m4a = files.path().join("tone.m4a");
    assert!(make(&m4a, &[&TONE[..], &["-c:a", "aac"]].concat()));
    let decoded = decode(File::open(&m4a).unwrap(), temp.path(), 60.0, &|| true);
    assert!(matches!(decoded, Err(DecodeError::Cancelled)));
    assert_eq!(listing(temp.path()), Vec::<PathBuf>::new());
}

/// The server hands over the upload's file just after writing it, positioned
/// at its end.
#[test]
fn an_upload_is_read_from_its_start_wherever_its_position_is() {
    if !ffmpeg() {
        return;
    }
    let files = tempfile::tempdir().unwrap();
    let temp = tempfile::tempdir().unwrap();
    let m4a = files.path().join("tone.m4a");
    assert!(make(&m4a, &[&TONE[..], &["-c:a", "aac"]].concat()));
    let mut upload = tempfile::tempfile_in(temp.path()).unwrap();
    upload.write_all(&std::fs::read(&m4a).unwrap()).unwrap();
    upload.seek(SeekFrom::End(0)).unwrap();
    let decoded = decode(upload, temp.path(), 60.0, &|| false).unwrap();
    assert_tone(&decoded);
    assert_eq!(listing(temp.path()), Vec::<PathBuf>::new());
}
