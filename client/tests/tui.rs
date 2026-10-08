//! The chat TUI's event loop against a fake server and a test terminal.

mod support;

use std::time::Duration;

use crossterm::event::{Event, KeyCode, KeyEvent, KeyModifiers};
use ratatui::Terminal;
use ratatui::backend::TestBackend;
use sadl::link::{Backoff, Link};
use sadl::protocol::{Call, Request};
use sadl::start::Start;
use sadl::tui::{self, app::App};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader, Lines};
use tokio::net::UnixListener;
use tokio::net::unix::{OwnedReadHalf, OwnedWriteHalf};
use tokio::sync::mpsc::{self, UnboundedSender};
use tokio::time::timeout;

const OPENED: &str = include_str!("../../protocol/fixtures/session.open.response.json");
const DELTA: &str = include_str!("../../protocol/fixtures/turn.delta.notification.json");
const END: &str = include_str!("../../protocol/fixtures/turn.end.notification.json");

/// The fake server's side of the connection. Unlike `support::Peer`, its
/// reads are cancel safe, so they can be retried on a timeout.
struct Server {
    lines: Lines<BufReader<OwnedReadHalf>>,
    writer: OwnedWriteHalf,
}

impl Server {
    async fn accept(listener: &UnixListener) -> Self {
        let (read, writer) = listener.accept().await.unwrap().0.into_split();
        let mut server = Self {
            lines: BufReader::new(read).lines(),
            writer,
        };
        let handshake = server.request().await;
        assert!(matches!(handshake.call, Call::Handshake(_)));
        server
            .write(r#"{"jsonrpc": "2.0", "id": 0, "result": {"protocol_version": 0}}"#)
            .await;
        server
    }

    async fn request(&mut self) -> Request {
        let line = self.lines.next_line().await.unwrap().expect("a request");
        serde_json::from_str(&line).expect("request")
    }

    async fn write(&mut self, line: &str) {
        self.writer
            .write_all(line.trim_end().as_bytes())
            .await
            .unwrap();
        self.writer.write_all(b"\n").await.unwrap();
    }

    /// Presses Enter until the client sends a request. The client ignores
    /// Enter until it has handled what the server already sent, which may
    /// race the key.
    async fn submit(&mut self, keys: &UnboundedSender<Event>) -> Request {
        for _ in 0..100 {
            keys.send(press(KeyCode::Enter, KeyModifiers::NONE))
                .unwrap();
            if let Ok(request) = timeout(Duration::from_millis(50), self.request()).await {
                return request;
            }
        }
        panic!("the client never sent the prompt");
    }
}

fn press(code: KeyCode, modifiers: KeyModifiers) -> Event {
    Event::Key(KeyEvent::new(code, modifiers))
}

fn type_text(keys: &UnboundedSender<Event>, text: &str) {
    for c in text.chars() {
        keys.send(press(KeyCode::Char(c), KeyModifiers::NONE))
            .unwrap();
    }
}

fn screen(terminal: &Terminal<TestBackend>) -> String {
    let buffer = terminal.backend().buffer();
    buffer
        .content()
        .chunks(usize::from(buffer.area.width))
        .map(|row| row.iter().map(|cell| cell.symbol()).collect::<String>())
        .collect::<Vec<_>>()
        .join("\n")
}

#[tokio::test]
async fn chats_with_the_server_until_ctrl_c() {
    let path = support::socket_path();
    let listener = UnixListener::bind(&path).unwrap();
    let (link, server) = tokio::join!(
        Link::connect(path, Backoff::default()),
        Server::accept(&listener)
    );
    let (mut link, mut server) = (link.expect("connected"), server);
    let (keys, mut events) = mpsc::unbounded_channel();

    let client = tokio::spawn(async move {
        let mut terminal = Terminal::new(TestBackend::new(80, 12)).unwrap();
        let mut app = App::new(Start::Open {
            cwd: "/home/u/proj".into(),
            model: None,
        });
        tui::run(&mut terminal, &mut link, &mut app, &mut events)
            .await
            .expect("run");
        terminal
    });

    let open = server.request().await;
    assert!(matches!(open.call, Call::SessionOpen(_)), "{open:?}");
    server.write(OPENED).await;

    type_text(&keys, "hi");
    let send = server.submit(&keys).await;
    match send.call {
        Call::SessionSend(params) => {
            assert_eq!(params.id, "s_01");
            assert_eq!(params.text, "hi");
        }
        other => panic!("expected session.send, got {other:?}"),
    }
    server
        .write(&format!(
            r#"{{"jsonrpc": "2.0", "id": {}, "result": {{"turn_id": "t_01"}}}}"#,
            send.id
        ))
        .await;
    server.write(DELTA).await;
    server.write(END).await;

    type_text(&keys, "again");
    let again = server.submit(&keys).await;
    assert!(matches!(again.call, Call::SessionSend(_)), "{again:?}");

    keys.send(press(KeyCode::Char('c'), KeyModifiers::CONTROL))
        .unwrap();
    let terminal = timeout(Duration::from_secs(5), client)
        .await
        .expect("the client quits")
        .unwrap();

    let shown = screen(&terminal);
    assert!(shown.contains("› hi"), "{shown}");
    assert!(shown.contains("Listing the files."), "{shown}");
    assert!(shown.contains("› again"), "{shown}");
    assert!(
        shown.contains("glm-5.3-flash · s_01 · 1834 in / 112 out"),
        "{shown}"
    );
    assert!(shown.contains("running (Esc to cancel)"), "{shown}");
}
