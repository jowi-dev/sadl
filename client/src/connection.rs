//! The client's socket connection to `sadld`. See `docs/protocol.md`.
//!
//! A [`Connection`] is one handshaken Unix socket carrying newline-delimited
//! JSON: [`Connection::send`] writes one request per line and
//! [`Connection::recv`] reads one server message per line.

use std::env;
use std::io;
use std::path::{Path, PathBuf};

use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader, Lines};
use tokio::net::UnixStream;
use tokio::net::unix::{OwnedReadHalf, OwnedWriteHalf};

use crate::protocol::{
    Call, HandshakeParams, HandshakeResult, JsonRpc, Outcome, PROTOCOL_VERSION, Request,
    ServerMessage,
};

/// The server socket under a runtime directory: `<dir>/sadl/sadld.sock`.
pub fn socket_path_in(runtime_dir: &Path) -> PathBuf {
    runtime_dir.join("sadl").join("sadld.sock")
}

/// The server socket under `$XDG_RUNTIME_DIR`, or `None` when it is unset.
pub fn default_socket_path() -> Option<PathBuf> {
    env::var_os("XDG_RUNTIME_DIR")
        .filter(|dir| !dir.is_empty())
        .map(|dir| socket_path_in(Path::new(&dir)))
}

/// One handshaken connection to the server.
#[derive(Debug)]
pub struct Connection {
    lines: Lines<BufReader<OwnedReadHalf>>,
    writer: OwnedWriteHalf,
    next_id: u64,
}

impl Connection {
    /// Connects to the socket at `path` and completes the handshake.
    ///
    /// Fails with the socket's I/O error, or with an error naming the
    /// server's reason if it rejects the handshake.
    pub async fn connect(path: &Path) -> io::Result<Self> {
        let (read, writer) = UnixStream::connect(path).await?.into_split();
        let mut conn = Self {
            lines: BufReader::new(read).lines(),
            writer,
            next_id: 0,
        };
        conn.handshake().await?;
        Ok(conn)
    }

    async fn handshake(&mut self) -> io::Result<()> {
        let id = self
            .send(Call::Handshake(HandshakeParams {
                protocol_version: PROTOCOL_VERSION,
            }))
            .await?;
        let response = match self.recv().await? {
            Some(ServerMessage::Response(response)) if response.id == Some(id) => response,
            Some(other) => {
                return Err(invalid_data(format!(
                    "expected the handshake response, got {other:?}"
                )));
            }
            None => {
                return Err(io::Error::new(
                    io::ErrorKind::UnexpectedEof,
                    "server closed the connection during the handshake",
                ));
            }
        };
        match response.into_typed::<HandshakeResult>()?.outcome {
            Outcome::Result(_) => Ok(()),
            Outcome::Error(error) => Err(io::Error::other(format!(
                "handshake rejected ({}): {}",
                error.code, error.message
            ))),
        }
    }

    /// Writes `call` as one request line and returns the id it was sent
    /// with. Ids count up from 0 on each connection.
    pub async fn send(&mut self, call: Call) -> io::Result<u64> {
        let id = self.next_id;
        self.next_id += 1;
        let request = Request {
            jsonrpc: JsonRpc::V2,
            id,
            call,
        };
        let mut line = serde_json::to_vec(&request)?;
        line.push(b'\n');
        self.writer.write_all(&line).await?;
        Ok(id)
    }

    /// Reads the next server message, or `None` once the server has closed
    /// the connection. A line that is not a valid message fails with
    /// [`io::ErrorKind::InvalidData`].
    ///
    /// Cancel safe: a message is never lost if this future is dropped.
    pub async fn recv(&mut self) -> io::Result<Option<ServerMessage>> {
        match self.lines.next_line().await? {
            Some(line) => ServerMessage::decode(&line)
                .map(Some)
                .map_err(io::Error::from),
            None => Ok(None),
        }
    }
}

fn invalid_data(message: String) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message)
}
