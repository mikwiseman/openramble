//! Development-only replay of one measured decoder spelling. The shipping
//! dictionary is unchanged until held-out recordings establish its behavior.
use std::io::{self, BufRead, Write};
use std::time::Instant;

use ramble_text::dictionary::DictionaryReplacement;
use ramble_text::{starter, TextPipeline};
use serde::Deserialize;

#[derive(Deserialize)]
struct Input {
    id: String,
    text: String,
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut replacements = starter::developer();
    replacements.push(DictionaryReplacement {
        id: "research-mixed-pull-request".into(),
        spoken: "pull реквест".into(),
        written: "pull request".into(),
        inflects: false,
        no_acoustic_boost: true,
        allows_phonetic_matching: false,
    });
    let pipeline = TextPipeline::with_replacements(replacements);
    let stdout = io::stdout();
    let mut output = stdout.lock();
    for line in io::stdin().lock().lines() {
        let input: Input = serde_json::from_str(&line?)?;
        let started = Instant::now();
        let result = pipeline.run(&input.text);
        serde_json::to_writer(
            &mut output,
            &serde_json::json!({
                "id": input.id, "text": result.output.text,
                "seconds": started.elapsed().as_secs_f64(),
                "after_dictionary": result.provenance.after_dictionary,
            }),
        )?;
        writeln!(output)?;
        output.flush()?;
    }
    Ok(())
}
