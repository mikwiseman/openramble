//! Where the engine's pieces begin and end.
//!
//! Everything here is in 20 ms frames of a loudness envelope (the RMS of each
//! frame above 100 Hz, see [`crate::decode::Envelope`]), so it is pure and
//! cheap: a 9-hour file is 1.6 million numbers.
//!
//! Two steps:
//!
//! 1. **Skip silence** (the gate). The recording's floor is its
//!    10th-percentile frame, and a frame is voiced when it is 6 dB above that
//!    floor. The floor is the track's own, so a quiet participant's words
//!    count as long as they stand 6 dB clear of their own microphone's noise,
//!    whatever its absolute level; only digital silence needs a fixed number,
//!    and there the floor is taken as -80 dBFS. Voiced frames less than 2 s
//!    apart form one island; an island with under 0.1 s of voiced frames is a
//!    click and goes. What is left gets 1 s of audio on each side, so a soft
//!    first or last syllable is not cut off. A per-participant meeting track
//!    is mostly the other people talking, which reaches this track as
//!    silence, so this is most of the server's saving.
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

/// A voiced frame is this many times louder than the floor: 6 dB.
const MARGIN: f32 = 2.0;
/// The floor is never taken as quieter than -80 dBFS, so digital silence and
/// dither do not make every faint sound voiced.
const LOWEST_FLOOR: f32 = 1e-4;
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

/// The pieces of several spans of a file, in samples, each with the index of
/// its span. A piece never leaves its span, so a span's exact edges hold.
pub fn pieces_of_spans(
    envelope: &[f32],
    samples: u64,
    spans: &[Range<u64>],
    cap_s: f32,
    gate: bool,
) -> Vec<(Range<u64>, usize)> {
    let frame = FRAME as u64;
    let mut pieces = Vec::new();
    for (index, span) in spans.iter().enumerate() {
        let span = span.start.min(samples)..span.end.min(samples);
        if span.is_empty() {
            continue;
        }
        let frames = (span.start / frame) as usize..span.end.div_ceil(frame) as usize;
        for piece in plan(envelope, frames, cap_s, gate) {
            let start = (piece.start as u64 * frame).max(span.start);
            let end = (piece.end as u64 * frame).min(span.end);
            if start < end {
                pieces.push((start..end, index));
            }
        }
    }
    pieces
}

/// The loudness above which a frame counts as voiced, from the whole recording.
fn threshold(envelope: &[f32]) -> f32 {
    let mut sorted = envelope.to_vec();
    let index = sorted.len() / 10;
    let (_, floor, _) = sorted.select_nth_unstable_by(index, f32::total_cmp);
    floor.max(LOWEST_FLOOR) * MARGIN
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
        // Only the cutting is under test. (This stand-in for speech is flat,
        // 0.06 to 0.14 with no pauses, so the gate finds no floor under it;
        // real speech swings 20 dB and more between syllables and pauses.)
        let pieces = plan(&envelope, 0..length, 20.0, false);
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
    fn spans_keep_their_exact_edges_and_their_index() {
        let mut envelope = room(100);
        put(&mut envelope, 10.0, &speech(30, 5));
        put(&mut envelope, 70.0, &speech(5, 6));
        let samples = 100 * 16_000 - 77;
        let spans = [5 * 16_000 + 123..45 * 16_000, 69 * 16_000..200 * 16_000];
        let pieces = pieces_of_spans(&envelope, samples, &spans, 20.0, false);
        let first: Vec<_> = pieces.iter().filter(|(_, i)| *i == 0).collect();
        let second: Vec<_> = pieces.iter().filter(|(_, i)| *i == 1).collect();
        assert_eq!(first.first().unwrap().0.start, 5 * 16_000 + 123);
        assert_eq!(first.last().unwrap().0.end, 45 * 16_000);
        assert_eq!(second.first().unwrap().0.start, 69 * 16_000);
        assert_eq!(second.last().unwrap().0.end, samples);
        for pair in first.windows(2) {
            assert_eq!(pair[0].0.end, pair[1].0.start);
        }
        // with the gate on, the second span keeps only its speech
        let gated = pieces_of_spans(&envelope, samples, &spans, 20.0, true);
        let second: Vec<_> = gated.iter().filter(|(_, i)| *i == 1).collect();
        assert_eq!(second.len(), 1);
        assert_eq!(second[0].0, 69 * 16_000..76 * 16_000);
        // a span past the end of the audio gives nothing
        let beyond = samples..samples + 9;
        assert!(pieces_of_spans(&envelope, samples, &[beyond], 20.0, false).is_empty());
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

    // The gate on real-shaped sound: 16 kHz samples through the decoder's own
    // envelope, over every kind of floor a participant's microphone leaves
    // between their turns.

    const RATE: usize = 16_000;

    #[derive(Debug, Clone, Copy)]
    enum Floor {
        DigitalSilence,
        White,
        /// Equal energy per octave down to a few hertz.
        Pink,
        /// Falling 6 dB an octave down to 5 Hz: rumble.
        Brown,
        /// Mains hum with its harmonics, 50 Hz and 100 Hz.
        Hum50,
        Hum100,
        /// Pink noise rolled off above 1 kHz, a little hum, and a slow swell
        /// of ±1.5 dB, as a ventilated room records.
        Room,
    }

    const NOISES: [Floor; 6] = [
        Floor::White,
        Floor::Pink,
        Floor::Brown,
        Floor::Hum50,
        Floor::Hum100,
        Floor::Room,
    ];

    struct Random(u64);

    impl Random {
        /// Uniform in [-1, 1).
        fn next(&mut self) -> f32 {
            self.0 = self
                .0
                .wrapping_mul(6_364_136_223_846_793_005)
                .wrapping_add(1_442_695_040_888_963_407);
            (self.0 >> 40) as f32 / (1u64 << 23) as f32 - 1.0
        }
    }

    fn rms(samples: &[f32]) -> f32 {
        (samples.iter().map(|x| x * x).sum::<f32>() / samples.len().max(1) as f32).sqrt()
    }

    fn scale_to(samples: &mut [f32], dbfs: f32) {
        let gain = 10f32.powf(dbfs / 20.0) / rms(samples).max(f32::MIN_POSITIVE);
        samples.iter_mut().for_each(|x| *x *= gain);
    }

    fn hum(n: usize, base: f32) -> Vec<f32> {
        (0..n)
            .map(|i| {
                let t = i as f32 / RATE as f32;
                [1.0, 0.5, 0.3, 0.2]
                    .iter()
                    .enumerate()
                    .map(|(k, a)| a * (std::f32::consts::TAU * base * (k + 1) as f32 * t).sin())
                    .sum()
            })
            .collect()
    }

    fn pink(n: usize, random: &mut Random) -> Vec<f32> {
        // Paul Kellet's economy filter
        let (mut b0, mut b1, mut b2) = (0.0, 0.0, 0.0);
        (0..n)
            .map(|_| {
                let white = random.next();
                b0 = 0.99765 * b0 + white * 0.099_046;
                b1 = 0.963 * b1 + white * 0.296_516_4;
                b2 = 0.57 * b2 + white * 1.052_691_3;
                b0 + b1 + b2 + white * 0.1848
            })
            .collect()
    }

    /// `seconds` of a floor whose RMS is `dbfs`.
    fn floor(kind: Floor, seconds: f32, dbfs: f32, seed: u64) -> Vec<f32> {
        let n = (seconds * RATE as f32) as usize;
        let mut random = Random(seed);
        let mut samples = match kind {
            Floor::DigitalSilence => return vec![0.0; n],
            Floor::White => (0..n).map(|_| random.next()).collect(),
            Floor::Pink => pink(n, &mut random),
            Floor::Brown => {
                let mut level = 0.0;
                (0..n)
                    .map(|_| {
                        level = 0.998 * level + random.next();
                        level
                    })
                    .collect()
            }
            Floor::Hum50 => hum(n, 50.0),
            Floor::Hum100 => hum(n, 100.0),
            Floor::Room => {
                let mut low = 0.0;
                let mut air: Vec<f32> = pink(n, &mut random)
                    .into_iter()
                    .map(|x| {
                        low += 0.33 * (x - low);
                        low
                    })
                    .collect();
                scale_to(&mut air, 0.0);
                let mut mains = hum(n, 50.0);
                scale_to(&mut mains, -10.0);
                air.iter()
                    .zip(&mains)
                    .enumerate()
                    .map(|(i, (a, m))| {
                        let swell = (std::f32::consts::TAU * 0.07 * i as f32 / RATE as f32).sin();
                        a * 10f32.powf(1.5 * swell / 20.0) + m
                    })
                    .collect()
            }
        };
        scale_to(&mut samples, dbfs);
        samples
    }

    /// One syllable of a 125 Hz voice: harmonics up to 4 kHz falling 6 dB an
    /// octave above 500 Hz, rising over 25 ms and falling over 40 ms.
    fn syllable(seconds: f32, loudness: f32) -> Vec<f32> {
        let period: Vec<f32> = (0..128)
            .map(|i| {
                (1..=32)
                    .map(|k| {
                        let weight = 1.0 / (1.0 + 125.0 * k as f32 / 500.0);
                        weight * (std::f32::consts::TAU * (k * i) as f32 / 128.0).sin()
                    })
                    .sum::<f32>()
            })
            .collect();
        let n = (seconds * RATE as f32) as usize;
        let (rise, fall) = (RATE / 40, RATE / 25);
        (0..n)
            .map(|i| {
                let shape = (i as f32 / rise as f32)
                    .min((n - i) as f32 / fall as f32)
                    .min(1.0);
                loudness * shape * period[i % 128]
            })
            .collect()
    }

    /// A stretch of speech: syllables of 120-260 ms, 20-60 ms apart inside a
    /// word and 150-350 ms between words. Returns the samples and the samples
    /// each syllable spans.
    fn utterance(seconds: f32, seed: u64) -> (Vec<f32>, Vec<Range<usize>>) {
        let mut random = Random(seed);
        let mut between = |from: f32, to: f32| from + (to - from) * (random.next() + 1.0) / 2.0;
        let end = (seconds * RATE as f32) as usize;
        let mut samples = Vec::new();
        let mut syllables = Vec::new();
        let mut in_word = 0;
        while samples.len() < end {
            let sound = syllable(between(0.12, 0.26), between(0.5, 1.0));
            syllables.push(samples.len()..samples.len() + sound.len());
            samples.extend(sound);
            in_word += 1;
            let pause = if in_word >= 3 || between(0.0, 1.0) < 0.3 {
                in_word = 0;
                between(0.15, 0.35)
            } else {
                between(0.02, 0.06)
            };
            samples.resize(samples.len() + (pause * RATE as f32) as usize, 0.0);
        }
        (samples, syllables)
    }

    /// "да": one syllable.
    fn da() -> (Vec<f32>, Vec<Range<usize>>) {
        let sound = syllable(0.2, 1.0);
        let len = sound.len();
        (sound, std::iter::once(0..len).collect())
    }

    /// A track being built: its samples and where its sounds are.
    struct Track {
        samples: Vec<f32>,
        /// Every syllable, in samples.
        syllables: Vec<Range<usize>>,
    }

    impl Track {
        fn new(kind: Floor, seconds: f32, dbfs: f32) -> Track {
            Track {
                samples: floor(kind, seconds, dbfs, 7),
                syllables: Vec::new(),
            }
        }

        /// Add `sound` at `at_s` with its RMS over the whole sound at `dbfs`.
        fn put(&mut self, at_s: f32, sound: (Vec<f32>, Vec<Range<usize>>), dbfs: f32) {
            let (mut samples, syllables) = sound;
            scale_to(&mut samples, dbfs);
            let at = (at_s * RATE as f32) as usize;
            for (i, x) in samples.iter().enumerate() {
                self.samples[at + i] += x;
            }
            self.syllables
                .extend(syllables.into_iter().map(|s| s.start + at..s.end + at));
        }

        fn pieces(&self) -> Vec<Range<usize>> {
            let mut envelope = crate::decode::Envelope::default();
            self.samples.iter().for_each(|x| envelope.push(*x));
            let envelope = envelope.finish();
            plan(&envelope, 0..envelope.len(), 20.0, true)
        }

        /// Syllables not wholly inside the pieces.
        fn lost(&self, pieces: &[Range<usize>]) -> usize {
            let inside = |frame: usize| pieces.iter().any(|p| p.contains(&frame));
            self.syllables
                .iter()
                .filter(|s| !(s.start / FRAME..s.end.div_ceil(FRAME)).all(inside))
                .count()
        }

        /// Seconds kept more than the 1 s pad away from every syllable.
        fn floor_kept_s(&self, pieces: &[Range<usize>]) -> f32 {
            let near = |frame: usize| {
                self.syllables
                    .iter()
                    .any(|s| frame + PAD + 1 >= s.start / FRAME && frame <= s.end / FRAME + PAD + 1)
            };
            let kept = pieces.iter().flat_map(|p| p.clone()).filter(|f| !near(*f));
            kept.count() as f32 / FRAMES_PER_SECOND as f32
        }
    }

    /// What a participant's track may keep of its floor beyond the pads: one
    /// stray island, 0.1 s over the threshold and its 1 s pads. A second kept
    /// costs a second of compute; a word dropped is gone.
    const STRAY_S: f32 = 2.5;

    /// A participant's track of 100 s: three turns and a short answer, the rest
    /// their floor.
    fn participant(kind: Floor, floor_dbfs: f32, speech_dbfs: f32) -> Track {
        let mut track = Track::new(kind, 100.0, floor_dbfs);
        track.put(8.0, utterance(10.0, 1), speech_dbfs);
        track.put(36.0, utterance(6.0, 2), speech_dbfs);
        track.put(58.0, da(), speech_dbfs);
        track.put(75.0, utterance(12.0, 3), speech_dbfs);
        track
    }

    #[test]
    fn a_floor_alone_gives_no_pieces() {
        for kind in NOISES {
            for level in [-90.0, -75.0, -65.0, -61.0, -55.0] {
                let track = Track::new(kind, 60.0, level);
                assert_eq!(track.pieces(), vec![], "{kind:?} at {level} dBFS");
            }
        }
    }

    #[test]
    fn a_participant_keeps_every_word_and_skips_the_floor() {
        let mut floors = vec![(Floor::DigitalSilence, -100.0)];
        for kind in NOISES {
            for level in [-90.0, -75.0, -65.0, -61.0, -55.0] {
                floors.push((kind, level));
            }
        }
        for (kind, level) in floors {
            let track = participant(kind, level, -26.0);
            let pieces = track.pieces();
            assert_eq!(track.lost(&pieces), 0, "{kind:?} at {level} dBFS");
            let kept = track.floor_kept_s(&pieces);
            assert!(kept <= STRAY_S, "{kind:?} at {level} dBFS kept {kept} s");
        }
    }

    #[test]
    fn a_quiet_participant_10_db_above_their_floor_keeps_every_word() {
        let mut floors = vec![(Floor::DigitalSilence, -100.0, -60.0)];
        for kind in NOISES {
            for level in [-75.0, -65.0, -61.0, -55.0] {
                floors.push((kind, level, level + 10.0));
            }
        }
        for (kind, level, speech) in floors {
            let track = participant(kind, level, speech);
            let pieces = track.pieces();
            assert_eq!(track.lost(&pieces), 0, "{kind:?} at {level} dBFS");
            let kept = track.floor_kept_s(&pieces);
            assert!(kept <= STRAY_S, "{kind:?} at {level} dBFS kept {kept} s");
        }
    }

    #[test]
    fn a_short_answer_alone_is_one_piece() {
        let ok = || {
            let mut first = syllable(0.12, 0.8);
            let gap = RATE * 3 / 100;
            first.resize(first.len() + gap, 0.0);
            let second_at = first.len();
            first.extend(syllable(0.18, 1.0));
            let len = first.len();
            (first, vec![0..second_at - gap, second_at..len])
        };
        for kind in NOISES {
            for level in [-75.0, -61.0, -55.0] {
                for (word, sound) in [("да", da()), ("ok", ok())] {
                    let mut track = Track::new(kind, 30.0, level);
                    track.put(15.0, sound, level + 10.0);
                    let pieces = track.pieces();
                    assert_eq!(pieces.len(), 1, "{word} over {kind:?} at {level} dBFS");
                    assert_eq!(track.lost(&pieces), 0, "{word} over {kind:?} at {level}");
                }
            }
        }
    }

    #[test]
    fn a_soft_word_ending_stays_inside_its_piece() {
        // a word whose last 0.4 s fades by 30 dB, as "-ть" or "-ся" trail off
        let soft = || {
            let (mut samples, mut syllables) = utterance(2.0, 9);
            let last = syllables.last().unwrap().end;
            samples.truncate(last);
            let mut tail = syllable(0.4, 0.8);
            let len = tail.len();
            for (i, x) in tail.iter_mut().enumerate() {
                *x *= 10f32.powf(-1.5 * i as f32 / len as f32);
            }
            syllables.push(last..last + len);
            samples.extend(tail);
            (samples, syllables)
        };
        for kind in NOISES {
            let mut track = Track::new(kind, 30.0, -61.0);
            track.put(10.0, soft(), -51.0);
            let pieces = track.pieces();
            assert_eq!(track.lost(&pieces), 0, "{kind:?}");
            assert_eq!(pieces.len(), 1, "{kind:?}");
        }
    }
}
