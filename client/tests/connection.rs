//! The client's line-framed socket connection against a fake server.

mod support;

use std::io::ErrorKind;
use std::path::Path;
use std::time::Duration;

use sadl::connection::{ConnectError, Connection, socket_path_in};
use sadl::protocol::{
    Call, HandshakeParams, JsonRpc, Request, ServerMessage, SessionIdParams, SessionListParams,
};
use support::Peer;
use tokio::net::UnixListener;

#[test]
fn the_socket_lives_under_the_runtime_dir() {
    assert_eq!(
        socket_path_in(Path::new("/run/user/1000")),
        Path::new("/run/user/1000/sadl/sadld.sock")
    );
}

#[tokio::test]
async fn connect_sends_the_handshake_first() {
    let path = support::socket_path();
    let listener = UnixListener::bind(&path).unwrap();
    let server = tokio::spawn(async move {
        let mut peer = Peer::new(listener.accept().await.unwrap().0);
        let request = peer.read_request().await;
        peer.write("{\"jsonrpc\": \"2.0\", \"id\": 0, \"result\": {\"protocol_version\": 0}}\n")
            .await;
        request
    });

    Connection::connect(&path).await.expect("connect");

    assert_eq!(
        server.await.unwrap(),
        Request {
            jsonrpc: JsonRpc::V2,
            id: 0,
            call: Call::Handshake(HandshakeParams {
                protocol_version: 0
            }),
        }
    );
}

#[tokio::test]
async fn connect_fails_when_the_server_rejects_the_version() {
    let path = support::socket_path();
    let listener = UnixListener::bind(&path).unwrap();
    tokio::spawn(async move {
        let mut peer = Peer::new(listener.accept().await.unwrap().0);
        peer.read_line().await;
        peer.write(include_str!(
            "../../protocol/fixtures/handshake.response.version-mismatch.json"
        ))
        .await;
        peer.write("\n").await;
        peer
    });

    let error = Connection::connect(&path).await.expect_err("rejected");

    assert!(
        matches!(&error, ConnectError::Rejected(e) if e.code == -32000),
        "{error:?}"
    );
    assert!(
        error.to_string().contains("unsupported protocol version"),
        "{error}"
    );
}

#[tokio::test]
async fn connect_fails_when_no_server_listens() {
    let error = Connection::connect(&support::socket_path())
        .await
        .expect_err("no server");

    assert!(
        matches!(&error, ConnectError::Io(e) if e.kind() == ErrorKind::NotFound),
        "{error:?}"
    );
}

#[tokio::test]
async fn send_writes_one_line_per_request_with_fresh_ids() {
    let path = support::socket_path();
    let listener = UnixListener::bind(&path).unwrap();
    let server = tokio::spawn(async move {
        let mut peer = Peer::new(listener.accept().await.unwrap().0);
        peer.accept_handshake().await;
        (peer.read_line().await, peer.read_line().await)
    });
    let mut conn = Connection::connect(&path).await.unwrap();

    let first = conn
        .send(Call::SessionList(SessionListParams {}))
        .await
        .unwrap();
    let second = conn
        .send(Call::SessionCancel(SessionIdParams { id: "s_1".into() }))
        .await
        .unwrap();

    let (line1, line2) = server.await.unwrap();
    assert_eq!((first, second), (1, 2));
    for (line, id) in [(&line1, 1), (&line2, 2)] {
        assert!(
            line.ends_with('\n') && line.matches('\n').count() == 1,
            "{line:?}"
        );
        assert_eq!(serde_json::from_str::<Request>(line).unwrap().id, id);
    }
}

#[tokio::test]
async fn recv_reassembles_lines_split_across_writes() {
    let path = support::socket_path();
    let listener = UnixListener::bind(&path).unwrap();
    tokio::spawn(async move {
        let mut peer = Peer::new(listener.accept().await.unwrap().0);
        peer.accept_handshake().await;
        let delta = include_str!("../../protocol/fixtures/turn.delta.notification.json").trim_end();
        let (head, tail) = delta.split_at(delta.len() / 2);
        peer.write(head).await;
        tokio::time::sleep(Duration::from_millis(20)).await;
        peer.write(&format!(
            "{tail}\n{{\"jsonrpc\": \"2.0\", \"id\": 1, \"result\": {{}}}}\n"
        ))
        .await;
    });
    let mut conn = Connection::connect(&path).await.unwrap();

    let first = conn.recv().await.unwrap().expect("first message");
    let second = conn.recv().await.unwrap().expect("second message");
    let end = conn.recv().await.unwrap();

    assert!(matches!(first, ServerMessage::Notification(_)), "{first:?}");
    assert!(matches!(second, ServerMessage::Response(_)), "{second:?}");
    assert_eq!(end, None, "server hung up");
}

#[tokio::test]
async fn recv_rejects_a_malformed_line() {
    let path = support::socket_path();
    let listener = UnixListener::bind(&path).unwrap();
    tokio::spawn(async move {
        let mut peer = Peer::new(listener.accept().await.unwrap().0);
        peer.accept_handshake().await;
        peer.write("{not json\n").await;
        peer
    });
    let mut conn = Connection::connect(&path).await.unwrap();

    let error = conn.recv().await.expect_err("malformed");

    assert_eq!(error.kind(), ErrorKind::InvalidData);
}
