//! `sadl ls`'s fetch against a fake server.

mod support;

use sadl::link::{Backoff, Link};
use sadl::list;
use sadl::protocol::Call;
use support::Peer;
use tokio::net::UnixListener;

#[tokio::test]
async fn fetches_the_persisted_sessions() {
    let path = support::socket_path();
    let listener = UnixListener::bind(&path).unwrap();
    let server = tokio::spawn(async move {
        let mut peer = Peer::new(listener.accept().await.unwrap().0);
        peer.accept_handshake().await;
        let request = peer.read_request().await;
        assert!(matches!(request.call, Call::SessionList(_)), "{request:?}");
        peer.write(&format!(
            "{{\"jsonrpc\": \"2.0\", \"id\": {}, \"result\": {{\"sessions\": [{{\"id\": \"s_1\", \"cwd\": \"/p\", \"model\": \"m\", \"updated_at\": \"2026-01-01T00:00:00Z\"}}]}}}}\n",
            request.id
        ))
        .await;
        peer
    });

    let mut link = Link::connect(path, Backoff::default()).await.unwrap();
    let sessions = list::fetch(&mut link).await.unwrap();
    let _peer = server.await.unwrap();

    assert_eq!(
        sessions.iter().map(|s| s.id.as_str()).collect::<Vec<_>>(),
        ["s_1"]
    );
}

#[tokio::test]
async fn a_list_error_is_reported() {
    let path = support::socket_path();
    let listener = UnixListener::bind(&path).unwrap();
    let server = tokio::spawn(async move {
        let mut peer = Peer::new(listener.accept().await.unwrap().0);
        peer.accept_handshake().await;
        let request = peer.read_request().await;
        peer.write(&format!(
            "{{\"jsonrpc\": \"2.0\", \"id\": {}, \"error\": {{\"code\": -32603, \"message\": \"db down\"}}}}\n",
            request.id
        ))
        .await;
        peer
    });

    let mut link = Link::connect(path, Backoff::default()).await.unwrap();
    let error = list::fetch(&mut link).await.unwrap_err();
    let _peer = server.await.unwrap();

    assert_eq!(error.to_string(), "cannot list sessions (-32603): db down");
}
