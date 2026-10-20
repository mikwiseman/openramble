//! Opt-in local benchmark adapter for the SAME core the macOS app calls.
//! Defaults match AppState.makePipeline and SettingsDefaults. No personal
//! dictionary, Return command, or added trailing space is enabled.
use std::io::{self, BufRead, Write};
use std::time::Instant;

use ramble_text::{starter, TextPipeline, TrailingCommand};
use serde::Deserialize;

#[derive(Deserialize)]
struct Input {
    id: String,
    text: String,
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let pipeline = TextPipeline::with_replacements(starter::developer());
    let stdout = io::stdout();
    let mut output = stdout.lock();
    for line in io::stdin().lock().lines() {
        let input: Input = serde_json::from_str(&line?)?;
        let start = Instant::now();
        let result = pipeline.run(&input.text);
        let seconds = start.elapsed().as_secs_f64();
        let command = result.output.command.map(|value| match value {
            TrailingCommand::PressReturn => "pressReturn",
            TrailingCommand::NewLine => "newLine",
        });
        serde_json::to_writer(
            &mut output,
            &serde_json::json!({
                "id": input.id, "text": result.output.text, "command": command,
                "after_dictionary": result.provenance.after_dictionary, "seconds": seconds,
            }),
        )?;
        writeln!(output)?;
        output.flush()?;
    }
    Ok(())
}
