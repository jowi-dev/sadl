//! `sadl -p`'s runner against a fake server.

mod support;

use sadl::headless::{self, Run};
use sadl::link::{Backoff, Link};
use sadl::protocol::{Call, StopReason, Usage};
use sadl::start::Start;
use support::Peer;
use tokio::net::UnixListener;

#[tokio::test]
async fn runs_one_turn_and_reports_its_outcome() {
    let path = support::socket_path();
    let listener = UnixListener::bind(&path).unwrap();
    let server = tokio::spawn(async move {
        let mut peer = Peer::new(listener.accept().await.unwrap().0);
        peer.accept_handshake().await;

        let open = peer.read_request().await;
        assert!(matches!(&open.call, Call::SessionOpen(p) if p.cwd == "/home/u/proj"));
        peer.write(&format!(
            "{{\"jsonrpc\": \"2.0\", \"id\": {}, \"result\": {{\"id\": \"s_1\", \"cwd\": \"/home/u/proj\", \"model\": \"m\", \"updated_at\": \"2026-01-01T00:00:00Z\"}}}}\n",
            open.id
        ))
        .await;

        let send = peer.read_request().await;
        assert!(matches!(&send.call, Call::SessionSend(p) if p.id == "s_1" && p.text == "hi"));
        peer.write(&format!(
            "{{\"jsonrpc\": \"2.0\", \"id\": {}, \"result\": {{\"turn_id\": \"t_1\"}}}}\n",
            send.id
        ))
        .await;
        peer.write(
            "{\"jsonrpc\": \"2.0\", \"method\": \"turn.delta\", \"params\": {\"session_id\": \"s_1\", \"turn_id\": \"t_1\", \"text\": \"Hello\"}}\n",
        )
        .await;
        peer.write(
            "{\"jsonrpc\": \"2.0\", \"method\": \"turn.end\", \"params\": {\"session_id\": \"s_1\", \"turn_id\": \"t_1\", \"stop_reason\": \"completed\", \"usage\": {\"input_tokens\": 3, \"output_tokens\": 1}}}\n",
        )
        .await;
        peer
    });

    let mut link = Link::connect(path, Backoff::default()).await.unwrap();
    let start = Start::Open {
        cwd: "/home/u/proj".into(),
        model: None,
    };
    let outcome = headless::run(&mut link, Run::new(start, "hi".into()))
        .await
        .unwrap();
    let _peer = server.await.unwrap();

    assert!(outcome.success);
    assert_eq!(outcome.session_id.as_deref(), Some("s_1"));
    assert_eq!(outcome.result, "Hello");
    assert_eq!(outcome.stop_reason, Some(StopReason::Completed));
    assert_eq!(
        outcome.usage,
        Usage {
            input_tokens: 3,
            output_tokens: 1,
        }
    );
}
