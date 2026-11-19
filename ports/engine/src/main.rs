use cliphoard_engine::{Engine, MAX_ITEMS, read_frame, write_frame};
use std::io;
use std::process::ExitCode;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    // Deliberate non-production transport. No default stdio, TCP, socket or unverified pipe.
    if args.as_slice().get(1).map(String::as_str) != Some("--synthetic-stdio") || args.len() != 2 {
        eprintln!("production_ipc_disabled_native_qualification_pending");
        return ExitCode::from(78);
    }
    let mut engine = Engine::new(MAX_ITEMS).expect("constant capacity");
    let mut input = io::stdin().lock();
    let mut output = io::stdout().lock();
    for _ in 0..10_000 {
        let frame = match read_frame(&mut input) {
            Ok(Some(frame)) => frame,
            Ok(None) => return ExitCode::SUCCESS,
            Err(_) => {
                eprintln!("framing_refused");
                return ExitCode::from(65);
            }
        };
        let result = engine.handle_bytes(&frame);
        let bytes = match serde_json::to_vec(&result) {
            Ok(value) => value,
            Err(_) => return ExitCode::from(70),
        };
        if write_frame(&mut output, &bytes).is_err() {
            eprintln!("transport_refused");
            return ExitCode::from(74);
        }
    }
    eprintln!("request_budget_exhausted");
    ExitCode::from(75)
}
