//! The client's socket connection to `sadld`. See `docs/protocol.md`.
//!
//! A [`Connection`] is one handshaken Unix socket carrying newline-delimited
//! JSON: [`Connection::send`] writes one request per line and
//! [`Connection::recv`] reads one server message per line.

use std::env;
use std::fmt;
use std::io;
use std::path::{Path, PathBuf};

use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader, Lines};
use tokio::net::UnixStream;
use tokio::net::unix::{OwnedReadHalf, OwnedWriteHalf};

use crate::protocol::{
    Call, ErrorObject, HandshakeParams, HandshakeResult, JsonRpc, Outcome, PROTOCOL_VERSION,
    Request, ServerMessage,
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

/// Why [`Connection::connect`] failed.
#[derive(Debug)]
pub enum ConnectError {
    /// The socket could not be reached, or broke or misbehaved during the
    /// handshake. Worth retrying.
    Io(io::Error),
    /// The server answered the handshake with an error, such as `-32000`
    /// for an unsupported protocol version. Retrying will not help.
    Rejected(ErrorObject),
}

impl fmt::Display for ConnectError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Io(error) => write!(f, "cannot reach sadld: {error}"),
            Self::Rejected(error) => {
                write!(
                    f,
                    "sadld rejected the handshake ({}): {}",
                    error.code, error.message
                )
            }
        }
    }
}

impl std::error::Error for ConnectError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Io(error) => Some(error),
            Self::Rejected(_) => None,
        }
    }
}

impl From<io::Error> for ConnectError {
    fn from(error: io::Error) -> Self {
        Self::Io(error)
    }
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
    pub async fn connect(path: &Path) -> Result<Self, ConnectError> {
        let (read, writer) = UnixStream::connect(path).await?.into_split();
        let mut conn = Self {
            lines: BufReader::new(read).lines(),
            writer,
            next_id: 0,
        };
        conn.handshake().await?;
        Ok(conn)
    }

    async fn handshake(&mut self) -> Result<(), ConnectError> {
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
                ))
                .into());
            }
            None => {
                return Err(io::Error::new(
                    io::ErrorKind::UnexpectedEof,
                    "server closed the connection during the handshake",
                )
                .into());
            }
        };
        let typed = response
            .into_typed::<HandshakeResult>()
            .map_err(io::Error::from)?;
        match typed.outcome {
            Outcome::Result(_) => Ok(()),
            Outcome::Error(error) => Err(ConnectError::Rejected(error)),
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
