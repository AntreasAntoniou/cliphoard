use cliphoard_engine::{
    Engine, MAX_FRAME, MAX_QUERY, MAX_RESULTS, MAX_TEXT, PREFIX, read_frame, write_frame,
};
use serde_json::{Value, json};
use std::io::{Cursor, Read};
fn call(engine: &mut Engine, command: Value) -> Value {
    engine
        .handle_bytes(&serde_json::to_vec(&json!({"version":1,"id":7,"command":command})).unwrap())
}
fn capture(engine: &mut Engine, label: &str) -> Value {
    call(
        engine,
        json!({"op":"captureSyntheticText","text":format!("{PREFIX}{label}")}),
    )
}
#[test]
fn capture_dedup_pin_trim_and_opaque_ids() {
    let mut engine = Engine::new(2).unwrap();
    let a = capture(&mut engine, "alpha");
    let id = a["result"]["item"]["id"].as_str().unwrap().to_owned();
    assert!(uuid::Uuid::parse_str(&id).is_ok());
    assert_eq!(
        call(&mut engine, json!({"op":"pin","itemId":id,"pinned":true}))["ok"],
        true
    );
    capture(&mut engine, "beta");
    capture(&mut engine, "gamma");
    let duplicate = capture(&mut engine, "alpha");
    assert_eq!(duplicate["result"]["item"]["id"], id);
    let list = call(&mut engine, json!({"op":"list","limit":20}));
    let items = list["result"]["items"].as_array().unwrap();
    assert_eq!(items.len(), 2);
    assert_eq!(items[0]["id"], id);
    assert_eq!(items[0]["pinned"], true);
    assert!(
        items
            .iter()
            .all(|i| i["text"].as_str().unwrap() != format!("{PREFIX}beta"))
    );
}
#[test]
fn bounded_fixture_only_search_select_clear_and_lock() {
    let mut engine = Engine::new(4).unwrap();
    let a = capture(&mut engine, "Alpha β");
    assert_eq!(
        call(
            &mut engine,
            json!({"op":"captureSyntheticText","text":"real clipboard data"})
        )["error"],
        "fixture_required"
    );
    assert_eq!(
        call(
            &mut engine,
            json!({"op":"search","query":"alpha","limit":1})
        )["result"]["items"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    let id = a["result"]["item"]["id"].clone();
    assert_eq!(
        call(&mut engine, json!({"op":"select","itemId":id}))["result"]["text"],
        format!("{PREFIX}Alpha β")
    );
    assert_eq!(
        call(&mut engine, json!({"op":"clearSynthetic"}))["result"]["removed"],
        1
    );
    capture(&mut engine, "other");
    assert_eq!(call(&mut engine, json!({"op":"lock"}))["ok"], true);
    assert_eq!(
        call(&mut engine, json!({"op":"status"}))["result"]["count"],
        0
    );
    assert_eq!(capture(&mut engine, "blocked")["error"], "locked");
    assert_eq!(
        call(&mut engine, json!({"op":"list","limit":1}))["error"],
        "locked"
    );
    assert_eq!(
        call(&mut engine, json!({"op":"select","itemId":id}))["error"],
        "locked"
    );
}
#[test]
fn reject_version_operation_unknown_fields_and_limits() {
    let mut engine = Engine::new(2).unwrap();
    assert_eq!(
        engine.handle_bytes(br#"{"version":2,"id":1,"command":{"op":"hello"}}"#)["error"],
        "unsupported_version"
    );
    for command in [
        json!({"op":"exec","command":"echo nope"}),
        json!({"op":"hello","path":"/tmp"}),
        json!({"op":"list","limit":MAX_RESULTS+1}),
        json!({"op":"search","query":"x".repeat(MAX_QUERY+1),"limit":1}),
        json!({"op":"captureSyntheticText","text":format!("{PREFIX}{}","x".repeat(MAX_TEXT))}),
        json!({"op":"select","itemId":"not-an-id"}),
    ] {
        assert_eq!(call(&mut engine, command)["ok"], false);
    }
    assert_eq!(engine.handle_bytes(b"{not-json")["ok"], false);
    assert_eq!(engine.handle_bytes(&[0xff])["ok"], false);
}
#[test]
fn frame_boundaries_utf8_and_truncation() {
    let mut encoded = Vec::new();
    write_frame(&mut encoded, "synthetic β".as_bytes()).unwrap();
    assert_eq!(
        read_frame(&mut Cursor::new(encoded)).unwrap().unwrap(),
        "synthetic β".as_bytes()
    );
    assert!(
        read_frame(&mut Cursor::new(Vec::<u8>::new()))
            .unwrap()
            .is_none()
    );
    for bytes in [
        vec![1],
        vec![2, 0, 0, 0, 1],
        vec![0, 0, 0, 0],
        ((MAX_FRAME + 1) as u32).to_le_bytes().to_vec(),
    ] {
        assert!(read_frame(&mut Cursor::new(bytes)).is_err());
    }
    assert!(write_frame(&mut Vec::new(), &vec![0; MAX_FRAME + 1]).is_err());
}
#[test]
fn oversized_length_is_rejected_before_payload_read_or_allocation() {
    struct HeaderOnly {
        header: Cursor<Vec<u8>>,
    }
    impl Read for HeaderOnly {
        fn read(&mut self, b: &mut [u8]) -> std::io::Result<usize> {
            assert!(
                self.header.position() < 4,
                "payload read after untrusted huge length"
            );
            self.header.read(b)
        }
    }
    let mut input = HeaderOnly {
        header: Cursor::new(u32::MAX.to_le_bytes().to_vec()),
    };
    assert!(read_frame(&mut input).is_err());
    assert_eq!(input.header.position(), 4);
}
#[test]
fn response_remains_frame_bounded_and_total_history_bounded() {
    let mut engine = Engine::new(200).unwrap();
    for i in 0..220 {
        let text = format!("{PREFIX}{i:04}{}", "x".repeat(MAX_TEXT - PREFIX.len() - 4));
        assert_eq!(
            call(
                &mut engine,
                json!({"op":"captureSyntheticText","text":text})
            )["ok"],
            true
        );
    }
    assert_eq!(
        call(&mut engine, json!({"op":"status"}))["result"]["count"],
        200
    );
    let result = call(&mut engine, json!({"op":"list","limit":20}));
    assert!(serde_json::to_vec(&result).unwrap().len() <= MAX_FRAME);
}

#[test]
fn pinned_history_refuses_growth_and_unknown_envelope_fields() {
    let mut engine = Engine::new(2).unwrap();
    for label in ["one", "two"] {
        let item = capture(&mut engine, label);
        assert_eq!(
            call(
                &mut engine,
                json!({"op":"pin","itemId":item["result"]["item"]["id"],"pinned":true})
            )["ok"],
            true
        );
    }
    assert_eq!(capture(&mut engine, "three")["error"], "history_full");
    assert_eq!(
        call(&mut engine, json!({"op":"status"}))["result"]["count"],
        2
    );
    for bytes in [
        br#"{"version":1,"id":1,"command":{"op":"hello"},"path":"ignored"}"#.as_slice(),
        br#"{"version":1,"id":1,"command":{"op":"status","sql":"ignored"}}"#,
    ] {
        assert_eq!(engine.handle_bytes(bytes)["ok"], false);
    }
}

#[test]
fn escaped_unicode_results_fit_encoded_frame_without_losing_continuity() {
    let mut engine = Engine::new(200).unwrap();
    for marker in ["\u{0001}", "\"", "\\", "\n", "界"] {
        for i in 0..20 {
            let prefix = format!("{PREFIX}{i:04}");
            let text = format!(
                "{prefix}{}",
                marker.repeat((MAX_TEXT - prefix.len()) / marker.len())
            );
            assert_eq!(
                call(
                    &mut engine,
                    json!({"op":"captureSyntheticText","text":text})
                )["ok"],
                true
            );
        }
        for command in [
            json!({"op":"list","limit":20}),
            json!({"op":"search","query":"","limit":20}),
        ] {
            let response = call(&mut engine, command);
            assert!(
                serde_json::to_vec(&response).unwrap().len() <= MAX_FRAME,
                "escaped JSON exceeds frame budget"
            );
            assert!(!response["result"]["items"].as_array().unwrap().is_empty());
        }
        assert_eq!(call(&mut engine, json!({"op":"status"}))["ok"], true);
        call(&mut engine, json!({"op":"clearSynthetic"}));
    }
}
