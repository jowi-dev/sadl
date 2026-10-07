//! A fake `sadld` on a real Unix socket, for client socket tests.

#![allow(dead_code)]

use std::path::PathBuf;
use std::sync::atomic::{AtomicU32, Ordering};

use sadl::protocol::{Call, Request};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;
use tokio::net::unix::{OwnedReadHalf, OwnedWriteHalf};

/// A socket path no other test uses. The file does not exist yet.
pub fn socket_path() -> PathBuf {
    static NEXT: AtomicU32 = AtomicU32::new(0);
    let n = NEXT.fetch_add(1, Ordering::Relaxed);
    let path = std::env::temp_dir().join(format!("sadl-{}-{n}.sock", std::process::id()));
    let _ = std::fs::remove_file(&path);
    path
}

/// The server's side of one accepted connection.
pub struct Peer {
    reader: BufReader<OwnedReadHalf>,
    writer: OwnedWriteHalf,
}

impl Peer {
    pub fn new(stream: UnixStream) -> Self {
        let (read, writer) = stream.into_split();
        Self {
            reader: BufReader::new(read),
            writer,
        }
    }

    /// The next raw line, including its `\n`; empty at EOF.
    pub async fn read_line(&mut self) -> String {
        let mut line = String::new();
        self.reader.read_line(&mut line).await.expect("read line");
        line
    }

    pub async fn read_request(&mut self) -> Request {
        serde_json::from_str(&self.read_line().await).expect("request")
    }

    pub async fn write(&mut self, bytes: &str) {
        self.writer
            .write_all(bytes.as_bytes())
            .await
            .expect("write");
        self.writer.flush().await.expect("flush");
    }

    /// Reads the handshake request and accepts it.
    pub async fn accept_handshake(&mut self) {
        let request = self.read_request().await;
        assert!(matches!(request.call, Call::Handshake(_)), "{request:?}");
        let id = request.id;
        self.write(&format!(
            "{{\"jsonrpc\": \"2.0\", \"id\": {id}, \"result\": {{\"protocol_version\": 0}}}}\n"
        ))
        .await;
    }
}
