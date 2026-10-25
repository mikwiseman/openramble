//! Where the engine's pieces begin and end.
//!
//! Everything here is in 20 ms frames of a loudness envelope (the RMS of each
//! frame), so it is pure and cheap: a 9-hour file is 1.6 million numbers.
//!
//! Two steps:
//!
//! 1. **Skip silence** (the gate). A frame is voiced when its RMS is above
//!    1.5 times the recording's 20th-percentile frame, and never below 0.0005.
//!    Voiced frames less than 2 s apart form one island; an island with under
//!    0.1 s of voiced frames is a click and goes. What is left gets 1 s of
//!    audio on each side, so a soft first or last syllable is not cut off. A
//!    per-participant meeting track is mostly the other people talking, which
//!    reaches this track as silence, so this is most of the server's saving.
//! 2. **Cut at pauses.** A region of at most `cap` seconds is one piece.
//!    A longer one is split into `n = ceil(d / (0.8 * cap))` nearly equal
//!    pieces, and each cut moves to the quietest point (smoothed over 200 ms)
//!    within `min(2.5 s, (cap - d/n) / 2)` of where an even split would put
//!    it. Every piece is therefore at most `cap` long. With a 20 s cap the
//!    even split is 10 to 16 s and a cut moves at most 2.5 s: long enough for
//!    the model to have context, short enough that it does not loop.

use std::ops::Range;

/// Envelope frames per second of audio.
pub const FRAMES_PER_SECOND: usize = 50;
/// Samples of 16 kHz audio in one envelope frame (20 ms).
pub const FRAME: usize = 16_000 / FRAMES_PER_SECOND;

const FLOOR_FACTOR: f32 = 1.5;
const MIN_THRESHOLD: f32 = 0.0005;
/// Audio kept on each side of an island: 1.0 s.
const PAD: usize = FRAMES_PER_SECOND;
/// Voiced frames closer than this (2.0 s) belong to one island.
const MERGE_GAP: usize = 2 * FRAMES_PER_SECOND;
/// An island with fewer voiced frames than this (0.1 s) is dropped.
const MIN_VOICED: usize = FRAMES_PER_SECOND / 10;
/// Frames on each side of a frame when looking for the quietest point (±100 ms).
const SMOOTH: usize = 5;
/// The furthest a cut moves from an even split: 2.5 s.
const MAX_SHIFT: usize = FRAMES_PER_SECOND * 5 / 2;
/// The share of the cap an even split aims for.
const TARGET: f64 = 0.8;

/// The pieces of `span` (in frames of `envelope`) to send to the engine, in
/// order, never overlapping, each at most `cap_s` seconds. With `gate` off the
/// whole span is covered; with it on, silence is left out.
pub fn plan(envelope: &[f32], span: Range<usize>, cap_s: f32, gate: bool) -> Vec<Range<usize>> {
    let span = span.start.min(envelope.len())..span.end.min(envelope.len());
    if span.is_empty() {
        return Vec::new();
    }
    let regions = if gate {
        voiced_regions(envelope, span)
    } else {
        vec![span]
    };
    let cap = ((cap_s * FRAMES_PER_SECOND as f32) as usize).max(1);
    regions
        .into_iter()
        .flat_map(|region| cut(envelope, region, cap))
        .collect()
}

/// The loudness above which a frame counts as voiced, from the whole recording.
fn threshold(envelope: &[f32]) -> f32 {
    let mut sorted = envelope.to_vec();
    let index = sorted.len() / 5;
    let (_, floor, _) = sorted.select_nth_unstable_by(index, f32::total_cmp);
    (*floor * FLOOR_FACTOR).max(MIN_THRESHOLD)
}

fn voiced_regions(envelope: &[f32], span: Range<usize>) -> Vec<Range<usize>> {
    let threshold = threshold(envelope);
    // (first voiced frame, one past the last, voiced frames)
    let mut islands: Vec<(usize, usize, usize)> = Vec::new();
    for frame in span.clone() {
        if envelope[frame] <= threshold {
            continue;
        }
        match islands.last_mut() {
            Some((_, end, voiced)) if frame - *end < MERGE_GAP => {
                *end = frame + 1;
                *voiced += 1;
            }
            _ => islands.push((frame, frame + 1, 1)),
        }
    }
    let mut regions: Vec<Range<usize>> = Vec::new();
    for (start, end, voiced) in islands {
        if voiced < MIN_VOICED {
            continue;
        }
        let padded = start.saturating_sub(PAD).max(span.start)..(end + PAD).min(span.end);
        match regions.last_mut() {
            Some(last) if padded.start <= last.end => last.end = last.end.max(padded.end),
            _ => regions.push(padded),
        }
    }
    regions
}

/// Split one region into pieces of at most `cap` frames, cutting at pauses.
fn cut(envelope: &[f32], region: Range<usize>, cap: usize) -> Vec<Range<usize>> {
    let length = region.len();
    if length <= cap {
        return vec![region];
    }
    let n = (length as f64 / (TARGET * cap as f64)).ceil() as usize;
    let longest_even = length.div_ceil(n);
    let reach = MAX_SHIFT.min(cap.saturating_sub(longest_even) / 2);
    let loudness = |frame: usize| -> f32 {
        let from = frame.saturating_sub(SMOOTH).max(region.start);
        let to = (frame + SMOOTH + 1).min(region.end);
        envelope[from..to].iter().sum()
    };
    let mut pieces = Vec::with_capacity(n);
    let mut start = region.start;
    for k in 1..n {
        let even = region.start + k * length / n;
        let from = even.saturating_sub(reach).max(start + 1);
        let to = (even + reach).min(region.end - 1);
        let at = (from..=to)
            .min_by(|&a, &b| {
                loudness(a)
                    .total_cmp(&loudness(b))
                    .then(a.abs_diff(even).cmp(&b.abs_diff(even)))
                    .then(a.cmp(&b))
            })
            .unwrap_or(even);
        pieces.push(start..at);
        start = at;
    }
    pieces.push(start..region.end);
    pieces
}

#[cfg(test)]
mod tests {
    use super::*;

    const SPEECH: f32 = 0.1;
    const S: usize = FRAMES_PER_SECOND;

    /// Speech-like loudness: never quiet, never flat.
    fn speech(seconds: usize, seed: u32) -> Vec<f32> {
        let mut state = seed.wrapping_mul(2_654_435_761).wrapping_add(1);
        (0..seconds * S)
            .map(|_| {
                state = state.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
                SPEECH * (0.6 + 0.8 * (state >> 8) as f32 / (1u32 << 24) as f32)
            })
            .collect()
    }

    /// Low steady noise, as a quiet room records.
    fn room(seconds: usize) -> Vec<f32> {
        (0..seconds * S)
            .map(|i| 0.002 * (1.0 + 0.02 * ((i % 7) as f32 - 3.0)))
            .collect()
    }

    fn put(envelope: &mut [f32], at_s: f32, words: &[f32]) {
        let at = (at_s * S as f32) as usize;
        envelope[at..at + words.len()].copy_from_slice(words);
    }

    fn assert_well_formed(pieces: &[Range<usize>], span: &Range<usize>, cap: usize) {
        let mut last_end = span.start;
        for piece in pieces {
            assert!(!piece.is_empty(), "{pieces:?}");
            assert!(
                piece.start >= last_end,
                "{pieces:?} overlap or are out of order"
            );
            assert!(piece.end <= span.end, "{pieces:?} leave {span:?}");
            assert!(piece.len() <= cap, "{piece:?} is longer than {cap}");
            last_end = piece.end;
        }
    }

    #[test]
    fn silence_and_digital_silence_give_no_pieces() {
        let quiet = room(60);
        assert!(plan(&quiet, 0..quiet.len(), 20.0, true).is_empty());
        let zeros = vec![0.0; 60 * S];
        assert!(plan(&zeros, 0..zeros.len(), 20.0, true).is_empty());
        assert!(plan(&[], 0..0, 20.0, true).is_empty());
    }

    #[test]
    fn a_word_in_a_minute_of_room_noise_gets_a_second_on_each_side() {
        let mut envelope = room(60);
        put(&mut envelope, 30.0, &speech(1, 1));
        assert_eq!(
            plan(&envelope, 0..envelope.len(), 20.0, true),
            vec![29 * S..32 * S]
        );
    }

    #[test]
    fn words_a_moment_apart_merge_and_words_far_apart_do_not() {
        let mut close = room(60);
        put(&mut close, 10.0, &speech(1, 1));
        put(&mut close, 12.5, &speech(1, 2));
        assert_eq!(
            plan(&close, 0..close.len(), 20.0, true),
            vec![9 * S..29 * S / 2]
        );

        let mut apart = room(60);
        put(&mut apart, 10.0, &speech(1, 1));
        put(&mut apart, 14.0, &speech(1, 2));
        assert_eq!(
            plan(&apart, 0..apart.len(), 20.0, true),
            vec![9 * S..12 * S, 13 * S..16 * S]
        );
    }

    #[test]
    fn a_click_is_not_speech() {
        let mut envelope = room(60);
        put(&mut envelope, 30.0, &[SPEECH; 4]);
        assert!(plan(&envelope, 0..envelope.len(), 20.0, true).is_empty());
        put(&mut envelope, 30.0, &[SPEECH; 5]);
        assert_eq!(plan(&envelope, 0..envelope.len(), 20.0, true).len(), 1);
    }

    #[test]
    fn continuous_speech_is_cut_at_its_pauses_into_contiguous_pieces() {
        let mut envelope = speech(95, 7);
        // n = ceil(95 / 16) = 6 pieces, so even cuts fall every 95/6 s and a
        // cut may move up to (20 - 95/6) / 2 = 2.08 s. Plant a pause near each.
        let length = envelope.len();
        let mut planted = Vec::new();
        for (k, shift) in (1..6).zip([75_isize, -95, 20, -40, 100]) {
            let at = (k * length / 6) as isize + shift;
            // a V-shaped dip, quieter than any speech frame, deepest at `at`
            for offset in -5_isize..=5 {
                envelope[(at + offset) as usize] = 0.05 * offset.unsigned_abs() as f32 / 6.0;
            }
            planted.push(at as usize);
        }
        let pieces = plan(&envelope, 0..length, 20.0, true);
        assert_eq!(pieces.len(), 6);
        assert_well_formed(&pieces, &(0..length), 20 * S);
        assert_eq!(pieces[0].start, 0);
        assert_eq!(pieces[5].end, length);
        for pair in pieces.windows(2) {
            assert_eq!(pair[0].end, pair[1].start, "pieces must be contiguous");
        }
        let cuts: Vec<usize> = pieces[1..].iter().map(|piece| piece.start).collect();
        assert_eq!(cuts, planted);
    }

    #[test]
    fn long_regions_split_into_pieces_near_sixteen_seconds() {
        for (seconds, count) in [(12, 1), (20, 1), (30, 2), (60, 4), (240, 15)] {
            let envelope = speech(seconds, seconds as u32);
            let pieces = plan(&envelope, 0..envelope.len(), 20.0, false);
            assert_eq!(pieces.len(), count, "{seconds} s");
            assert_well_formed(&pieces, &(0..envelope.len()), 20 * S);
            assert!(
                pieces.iter().all(|piece| piece.len() >= 10 * S),
                "{pieces:?}"
            );
        }
    }

    #[test]
    fn pieces_stay_ordered_inside_the_span_whatever_the_audio() {
        for seed in 0..40_u32 {
            let mut envelope = room(400);
            let mut state = seed.wrapping_mul(747_796_405).wrapping_add(2_891_336_453);
            let mut next = |limit: usize| {
                state = state.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
                (state >> 8) as usize % limit
            };
            for _ in 0..next(12) {
                let length = 1 + next(90);
                let at = next(400 - length);
                put(&mut envelope, at as f32, &speech(length, seed));
            }
            let from = next(100) * S;
            let to = from + next(300) * S;
            for cap in [5.0, 14.0, 20.0, 120.0] {
                for gate in [true, false] {
                    let pieces = plan(&envelope, from..to, cap, gate);
                    assert_well_formed(&pieces, &(from..to), (cap * S as f32) as usize);
                }
            }
        }
    }

    #[test]
    fn without_the_gate_the_whole_span_is_covered() {
        let mut envelope = room(100);
        put(&mut envelope, 40.0, &speech(5, 3));
        let pieces = plan(&envelope, 10 * S..90 * S, 20.0, false);
        assert_eq!(pieces.first().unwrap().start, 10 * S);
        assert_eq!(pieces.last().unwrap().end, 90 * S);
        for pair in pieces.windows(2) {
            assert_eq!(pair[0].end, pair[1].start);
        }
        // and a span past the end of the audio is clipped to it
        assert_eq!(
            plan(&envelope, 95 * S..200 * S, 20.0, false),
            vec![95 * S..100 * S]
        );
    }

    #[test]
    fn the_gate_never_reaches_outside_the_span() {
        let mut envelope = room(60);
        put(&mut envelope, 20.0, &speech(10, 4));
        assert_eq!(
            plan(&envelope, 20 * S + 10..25 * S, 20.0, true),
            vec![20 * S + 10..25 * S]
        );
    }
}
