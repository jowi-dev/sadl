//! Every golden fixture in `protocol/fixtures/` must decode into the client's
//! protocol types and re-encode to the same JSON value.

use std::fs;
use std::path::PathBuf;

use sadl::protocol::{
    HandshakeResult, Notification, Outcome, Request, Response, ServerMessage, SessionCancelResult,
    SessionInfo, SessionListResult, SessionPermitResult, SessionSendResult,
};
use serde::Serialize;
use serde::de::DeserializeOwned;
use serde_json::Value;

fn fixtures_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../protocol/fixtures")
}

fn roundtrip<T: DeserializeOwned + Serialize>(original: &Value) -> Value {
    let decoded: T = serde_json::from_value(original.clone()).expect("decode");
    serde_json::to_value(&decoded).expect("encode")
}

/// Splits `<method>.<kind>[.<variant>].json` into `(method, kind)`.
fn parse_name(name: &str) -> (String, String) {
    let stem = name.strip_suffix(".json").expect("fixture must be .json");
    let parts: Vec<&str> = stem.split('.').collect();
    let kind_at = parts
        .iter()
        .rposition(|p| matches!(*p, "request" | "response" | "notification"))
        .unwrap_or_else(|| panic!("{name}: no request/response/notification segment"));
    (parts[..kind_at].join("."), parts[kind_at].to_string())
}

fn roundtrip_fixture(method: &str, kind: &str, original: &Value) -> Value {
    match (kind, method) {
        ("request", _) => roundtrip::<Request>(original),
        ("notification", _) => roundtrip::<Notification>(original),
        ("response", "handshake") => roundtrip::<Response<HandshakeResult>>(original),
        ("response", "session.open" | "session.resume") => {
            roundtrip::<Response<SessionInfo>>(original)
        }
        ("response", "session.send" | "session.compact") => {
            roundtrip::<Response<SessionSendResult>>(original)
        }
        ("response", "session.cancel") => roundtrip::<Response<SessionCancelResult>>(original),
        ("response", "session.permit") => roundtrip::<Response<SessionPermitResult>>(original),
        ("response", "session.list") => roundtrip::<Response<SessionListResult>>(original),
        _ => panic!("no response type for method {method}"),
    }
}

#[test]
fn every_fixture_roundtrips_losslessly() {
    let mut count = 0;
    for entry in fs::read_dir(fixtures_dir()).expect("fixtures dir") {
        let path = entry.expect("dir entry").path();
        let name = path.file_name().unwrap().to_str().unwrap().to_string();
        let original: Value =
            serde_json::from_str(&fs::read_to_string(&path).expect("read")).expect("valid json");
        let (method, kind) = parse_name(&name);

        let reencoded = roundtrip_fixture(&method, &kind, &original);

        assert_eq!(reencoded, original, "{name} did not roundtrip");
        count += 1;
    }
    assert!(count > 0, "no fixtures found");
}

/// Every server → client fixture must decode from its wire line without the
/// reader knowing its kind up front, as the client socket reads them.
#[test]
fn every_server_fixture_roundtrips_as_a_server_message() {
    let mut count = 0;
    for entry in fs::read_dir(fixtures_dir()).expect("fixtures dir") {
        let path = entry.expect("dir entry").path();
        let name = path.file_name().unwrap().to_str().unwrap().to_string();
        let (_, kind) = parse_name(&name);
        let expect_response = match kind.as_str() {
            "response" => true,
            "notification" => false,
            _ => continue,
        };
        let line = fs::read_to_string(&path).expect("read");
        let original: Value = serde_json::from_str(&line).expect("valid json");

        let decoded = ServerMessage::decode(line.trim_end()).expect("decode");

        assert_eq!(
            matches!(decoded, ServerMessage::Response(_)),
            expect_response,
            "{name} decoded as the wrong kind"
        );
        assert_eq!(
            serde_json::to_value(&decoded).expect("encode"),
            original,
            "{name} did not roundtrip"
        );
        count += 1;
    }
    assert!(count > 0, "no server fixtures found");
}

#[test]
fn a_raw_response_converts_to_its_typed_result() {
    let line = fs::read_to_string(fixtures_dir().join("session.send.response.json")).unwrap();
    let ServerMessage::Response(raw) = ServerMessage::decode(&line).unwrap() else {
        panic!("not a response");
    };

    let typed: Response<SessionSendResult> = raw.into_typed().expect("typed");

    assert_eq!(
        typed.outcome,
        Outcome::Result(SessionSendResult {
            turn_id: "t_01".into()
        })
    );
}

#[test]
fn a_server_message_must_be_a_valid_response_or_notification() {
    assert!(ServerMessage::decode("not json").is_err());
    assert!(
        ServerMessage::decode(r#"{"jsonrpc": "2.0", "method": "nope", "params": {}}"#).is_err()
    );
    assert!(ServerMessage::decode(r#"{"jsonrpc": "2.0", "id": 1}"#).is_err());
}

#[test]
fn request_method_must_match_params() {
    let mismatched = serde_json::json!({
        "jsonrpc": "2.0", "id": 1, "method": "session.send", "params": {"id": "s_01"}
    });
    assert!(serde_json::from_value::<Request>(mismatched).is_err());
}

#[test]
fn jsonrpc_version_must_be_2_0() {
    let wrong = serde_json::json!({
        "jsonrpc": "1.0", "id": 1, "method": "session.list", "params": {}
    });
    assert!(serde_json::from_value::<Request>(wrong).is_err());
}
