//! A server connection that survives the server going away.
//!
//! A [`Link`] owns one [`Connection`] at a time. When the server hangs up,
//! [`Link::recv`] reconnects with exponential [`Backoff`] and reports
//! [`Incoming::Reconnected`], so the caller can resubscribe its sessions and
//! give up on requests the old connection never answered.

use std::io;
use std::path::{Path, PathBuf};
use std::time::Duration;

use crate::connection::{ConnectError, Connection};
use crate::protocol::{Call, ServerMessage};

/// Exponential backoff between reconnect attempts: the delay starts at
/// `initial`, doubles after each failed attempt, and stops growing at `max`.
#[derive(Debug, Clone)]
pub struct Backoff {
    initial: Duration,
    max: Duration,
    next: Duration,
}

impl Backoff {
    pub fn new(initial: Duration, max: Duration) -> Self {
        Self {
            initial,
            max,
            next: initial,
        }
    }

    /// The delay before the next attempt. Each call doubles the following
    /// one, up to `max`.
    pub fn next_delay(&mut self) -> Duration {
        let delay = self.next;
        self.next = (delay * 2).min(self.max);
        delay
    }

    /// Starts over from `initial`, after a successful attempt.
    pub fn reset(&mut self) {
        self.next = self.initial;
    }
}

impl Default for Backoff {
    /// 100 ms doubling up to 5 s.
    fn default() -> Self {
        Self::new(Duration::from_millis(100), Duration::from_secs(5))
    }
}

/// What [`Link::recv`] read.
#[derive(Debug, PartialEq)]
pub enum Incoming {
    Message(ServerMessage),
    /// The server went away and a new connection is handshaken. Requests
    /// sent on the old connection will never be answered, and the new one
    /// is subscribed to no sessions.
    Reconnected,
    /// A line that is not a valid server message. The connection stays up.
    Malformed(String),
}

/// A self-healing connection to the server socket at a fixed path.
#[derive(Debug)]
pub struct Link {
    path: PathBuf,
    backoff: Backoff,
    conn: Connection,
}

impl Link {
    /// Connects to `path`, retrying with `backoff` until the server accepts
    /// the handshake. Fails only if the server rejects the handshake; wrap
    /// it in a timeout to bound the wait.
    pub async fn connect(path: PathBuf, mut backoff: Backoff) -> Result<Self, ConnectError> {
        let conn = connect_with_retry(&path, &mut backoff).await?;
        Ok(Self {
            path,
            backoff,
            conn,
        })
    }

    /// Sends `call` on the current connection and returns its request id.
    /// A write to a server that has gone away fails; the next
    /// [`Link::recv`] reconnects.
    pub async fn send(&mut self, call: Call) -> io::Result<u64> {
        self.conn.send(call).await
    }

    /// Reads the next message. If the server has gone away, reconnects
    /// first and returns [`Incoming::Reconnected`]. Fails only if the
    /// server rejects the handshake on reconnect.
    pub async fn recv(&mut self) -> Result<Incoming, ConnectError> {
        match self.conn.recv().await {
            Ok(Some(message)) => Ok(Incoming::Message(message)),
            Err(error) if error.kind() == io::ErrorKind::InvalidData => {
                Ok(Incoming::Malformed(error.to_string()))
            }
            Ok(None) | Err(_) => {
                self.conn = connect_with_retry(&self.path, &mut self.backoff).await?;
                Ok(Incoming::Reconnected)
            }
        }
    }
}

async fn connect_with_retry(
    path: &Path,
    backoff: &mut Backoff,
) -> Result<Connection, ConnectError> {
    loop {
        match Connection::connect(path).await {
            Ok(conn) => {
                backoff.reset();
                return Ok(conn);
            }
            Err(ConnectError::Io(_)) => tokio::time::sleep(backoff.next_delay()).await,
            Err(rejected) => return Err(rejected),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ms(n: u64) -> Duration {
        Duration::from_millis(n)
    }

    #[test]
    fn delays_double_up_to_the_max() {
        let mut backoff = Backoff::new(ms(10), ms(50));

        let delays: Vec<_> = (0..5).map(|_| backoff.next_delay()).collect();

        assert_eq!(delays, [ms(10), ms(20), ms(40), ms(50), ms(50)]);
    }

    #[test]
    fn reset_starts_over() {
        let mut backoff = Backoff::new(ms(10), ms(50));
        backoff.next_delay();
        backoff.next_delay();

        backoff.reset();

        assert_eq!(backoff.next_delay(), ms(10));
    }
}
