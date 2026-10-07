//! Starting `sadld` when its socket is missing.
//!
//! [`connect_or_start`] connects as [`Connection::connect`] does, but when
//! the socket does not exist or refuses the connection it launches the
//! server and polls the socket until the server answers or a timeout
//! passes. An exclusive lock on `sadld.lock` beside the socket makes sure
//! that of many clients starting at once, only one launches a server; the
//! rest wait for it.

use std::fmt;
use std::fs::{DirBuilder, File, OpenOptions, TryLockError};
use std::io;
use std::os::unix::fs::DirBuilderExt;
use std::path::{Path, PathBuf};
use std::time::Duration;

use tokio::time::Instant;

use crate::connection::{ConnectError, Connection};
use crate::link::Backoff;

/// Why [`connect_or_start`] failed.
#[derive(Debug)]
pub enum StartError {
    /// Connecting failed for a reason launching a server will not fix, such
    /// as a rejected handshake.
    Connect(ConnectError),
    /// The lock file could not be taken, or the launcher failed.
    Launch(io::Error),
    /// The server did not answer on the socket within this long.
    Timeout(Duration),
}

impl fmt::Display for StartError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Connect(error) => error.fmt(f),
            Self::Launch(error) => write!(f, "cannot start sadld: {error}"),
            Self::Timeout(timeout) => {
                write!(f, "sadld did not start listening within {timeout:?}")
            }
        }
    }
}

impl std::error::Error for StartError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Connect(error) => Some(error),
            Self::Launch(error) => Some(error),
            Self::Timeout(_) => None,
        }
    }
}

/// Connects to the server socket at `path`, calling `launch` to start the
/// server if the socket is missing or refuses connections, then polling it
/// until the server completes the handshake or `timeout` passes.
///
/// `launch` must return once the server is spawned, without waiting for it
/// to listen. It is
/// called at most once, and only by the client that holds the lock on
/// `sadld.lock` in the socket's directory (created owner-only if missing).
/// The lock is held until this returns.
pub async fn connect_or_start<F>(
    path: &Path,
    timeout: Duration,
    mut launch: F,
) -> Result<Connection, StartError>
where
    F: FnMut() -> io::Result<()>,
{
    let deadline = Instant::now() + timeout;
    let mut backoff = Backoff::new(Duration::from_millis(10), Duration::from_millis(250));
    let mut lock = None;
    loop {
        if let Some(conn) = try_connect(path).await? {
            return Ok(conn);
        }
        if lock.is_none()
            && let Some(file) = try_lock(path).map_err(StartError::Launch)?
        {
            // Whoever held the lock before may have started the server since.
            if let Some(conn) = try_connect(path).await? {
                return Ok(conn);
            }
            launch().map_err(StartError::Launch)?;
            lock = Some(file);
        }
        let now = Instant::now();
        if now >= deadline {
            return Err(StartError::Timeout(timeout));
        }
        tokio::time::sleep(backoff.next_delay().min(deadline - now)).await;
    }
}

/// Connects, or returns `None` if no server is listening on `path`.
async fn try_connect(path: &Path) -> Result<Option<Connection>, StartError> {
    match Connection::connect(path).await {
        Ok(conn) => Ok(Some(conn)),
        Err(ConnectError::Io(error))
            if matches!(
                error.kind(),
                io::ErrorKind::NotFound | io::ErrorKind::ConnectionRefused
            ) =>
        {
            Ok(None)
        }
        Err(error) => Err(StartError::Connect(error)),
    }
}

/// Takes the launch lock for the socket at `path` without blocking, or
/// returns `None` if another client holds it.
fn try_lock(path: &Path) -> io::Result<Option<File>> {
    if let Some(dir) = path.parent() {
        DirBuilder::new().recursive(true).mode(0o700).create(dir)?;
    }
    let file = OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .open(lock_path(path))?;
    match file.try_lock() {
        Ok(()) => Ok(Some(file)),
        Err(TryLockError::WouldBlock) => Ok(None),
        Err(TryLockError::Error(error)) => Err(error),
    }
}

fn lock_path(socket: &Path) -> PathBuf {
    socket.with_extension("lock")
}
