use ai::{AnthropicConfig, PartType, Runtime, Tool};
use std::env;
use std::error::Error;
use std::io::{self, Write};

fn main() {
    if let Err(error) = run() {
        eprintln!("error: {error}");
        std::process::exit(1);
    }
}

fn run() -> Result<(), Box<dyn Error>> {
    let api_key = match env::var("ANTHROPIC_API_KEY") {
        Ok(value) if !value.is_empty() => value,
        _ => {
            println!("ANTHROPIC_API_KEY is not set; no provider request was sent.");
            println!("Set it and rerun this command to start the streaming chat.");
            return Ok(());
        }
    };
    let model_id = env::var("AI_MODEL").unwrap_or_else(|_| "claude-haiku-4-5-20251001".to_owned());
    let prompt = env::args().skip(1).collect::<Vec<_>>().join(" ");
    let prompt = if prompt.is_empty() {
        "Use the weather tool for Paris, then answer in one short sentence.".to_owned()
    } else {
        prompt
    };

    let runtime = Runtime::new()?;
    let provider = runtime.anthropic(AnthropicConfig::new(&api_key))?;
    let model = provider.language_model(&model_id)?;
    let weather = Tool::new(
        "weather",
        "Return the current weather for a city",
        r#"{"type":"object","properties":{"city":{"type":"string"}},"required":["city"],"additionalProperties":false}"#,
        |input_json| {
            println!("\n[tool] weather input: {input_json}");
            Ok(r#"{"city":"Paris","temperature_c":21,"condition":"sunny"}"#.to_owned())
        },
    );
    let options = format!(
        r#"{{"prompt":"{}","maxSteps":2,"maxRetries":1}}"#,
        escape_json(&prompt)
    );

    println!("model: {model_id}");
    println!("user: {prompt}");
    print!("assistant: ");
    io::stdout().flush()?;
    let stream = model.stream_text(&options, &[weather])?;
    for part in stream {
        let part = part?;
        if part.kind == PartType::TextDelta {
            print!("{}", part.text);
            io::stdout().flush()?;
        }
    }
    println!();
    Ok(())
}

fn escape_json(value: &str) -> String {
    let mut output = String::with_capacity(value.len());
    for character in value.chars() {
        match character {
            '"' => output.push_str("\\\""),
            '\\' => output.push_str("\\\\"),
            '\n' => output.push_str("\\n"),
            '\r' => output.push_str("\\r"),
            '\t' => output.push_str("\\t"),
            value if value <= '\u{001f}' => {
                use std::fmt::Write as _;
                write!(output, "\\u{:04x}", value as u32).expect("String writes cannot fail");
            }
            value => output.push(value),
        }
    }
    output
}
