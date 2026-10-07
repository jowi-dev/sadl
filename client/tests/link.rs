//! The reconnecting link against a fake server that comes and goes.

mod support;

use std::time::Duration;

use sadl::connection::ConnectError;
use sadl::link::{Backoff, Incoming, Link};
use sadl::protocol::{Call, ServerMessage, SessionListParams};
use support::Peer;
use tokio::net::UnixListener;
use tokio::time::timeout;

const DELTA: &str = include_str!("../../protocol/fixtures/turn.delta.notification.json");

fn fast_backoff() -> Backoff {
    Backoff::new(Duration::from_millis(5), Duration::from_millis(20))
}

async fn within<T>(future: impl Future<Output = T>) -> T {
    timeout(Duration::from_secs(5), future)
        .await
        .expect("timed out")
}

#[tokio::test]
async fn connect_retries_until_the_server_appears() {
    let path = support::socket_path();
    let client = tokio::spawn(Link::connect(path.clone(), fast_backoff()));
    tokio::time::sleep(Duration::from_millis(50)).await;

    let listener = UnixListener::bind(&path).unwrap();
    let mut peer = Peer::new(listener.accept().await.unwrap().0);
    peer.accept_handshake().await;

    let mut link = within(client).await.unwrap().expect("connected");
    let id = link
        .send(Call::SessionList(SessionListParams {}))
        .await
        .unwrap();
    assert_eq!(id, 1);
    assert!(peer.read_line().await.contains("session.list"));
}

#[tokio::test]
async fn connect_gives_up_when_the_server_rejects_the_handshake() {
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

    let result = within(Link::connect(path, fast_backoff())).await;

    match result {
        Err(ConnectError::Rejected(error)) => assert_eq!(error.code, -32000),
        other => panic!("expected a rejection, got {other:?}"),
    }
}

#[tokio::test]
async fn recv_reconnects_after_the_server_goes_away() {
    let path = support::socket_path();
    let listener = UnixListener::bind(&path).unwrap();
    let server = tokio::spawn(async move {
        let mut first = Peer::new(listener.accept().await.unwrap().0);
        first.accept_handshake().await;
        first.write(DELTA).await;
        drop(first);

        let mut second = Peer::new(listener.accept().await.unwrap().0);
        second.accept_handshake().await;
        second.write(DELTA).await;
        second
    });
    let mut link = within(Link::connect(path, fast_backoff())).await.unwrap();

    let before = within(link.recv()).await.unwrap();
    let reconnected = within(link.recv()).await.unwrap();
    let after = within(link.recv()).await.unwrap();

    assert!(matches!(
        before,
        Incoming::Message(ServerMessage::Notification(_))
    ));
    assert_eq!(reconnected, Incoming::Reconnected);
    assert!(matches!(
        after,
        Incoming::Message(ServerMessage::Notification(_))
    ));
    server.await.unwrap();
}

#[tokio::test]
async fn recv_reports_a_malformed_line_and_keeps_the_connection() {
    let path = support::socket_path();
    let listener = UnixListener::bind(&path).unwrap();
    tokio::spawn(async move {
        let mut peer = Peer::new(listener.accept().await.unwrap().0);
        peer.accept_handshake().await;
        peer.write("{not json\n").await;
        peer.write(DELTA).await;
        peer
    });
    let mut link = within(Link::connect(path, fast_backoff())).await.unwrap();

    let bad = within(link.recv()).await.unwrap();
    let good = within(link.recv()).await.unwrap();

    assert!(matches!(bad, Incoming::Malformed(_)), "{bad:?}");
    assert!(matches!(
        good,
        Incoming::Message(ServerMessage::Notification(_))
    ));
}
