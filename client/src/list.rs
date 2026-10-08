//! `sadl ls`: the server's persisted sessions as a table.

use crate::link::{Incoming, Link};
use crate::protocol::{
    Call, Outcome, ServerMessage, SessionInfo, SessionListParams, SessionListResult,
};
use crate::tui::wrap::columns;

/// Why [`fetch`] failed.
pub type ListError = Box<dyn std::error::Error + Send + Sync>;

/// Asks the server for every persisted session, most recently updated
/// first.
pub async fn fetch(link: &mut Link) -> Result<Vec<SessionInfo>, ListError> {
    let id = link
        .send(Call::SessionList(SessionListParams {}))
        .await
        .map_err(|error| format!("cannot reach sadld: {error}"))?;
    loop {
        match link.recv().await? {
            Incoming::Message(ServerMessage::Response(response)) if response.id == Some(id) => {
                return match response.into_typed::<SessionListResult>()?.outcome {
                    Outcome::Result(result) => Ok(result.sessions),
                    Outcome::Error(error) => Err(format!(
                        "cannot list sessions ({}): {}",
                        error.code, error.message
                    )
                    .into()),
                };
            }
            Incoming::Reconnected => return Err("lost the connection to sadld".into()),
            Incoming::Message(_) | Incoming::Malformed(_) => {}
        }
    }
}

/// `sessions` as aligned columns under a header, one per line, or a note
/// that there are none.
pub fn format(sessions: &[SessionInfo]) -> String {
    if sessions.is_empty() {
        return "no sessions\n".to_string();
    }
    let header = ["ID", "UPDATED", "MODEL", "CWD"];
    let rows: Vec<[&str; 4]> = sessions
        .iter()
        .map(|s| [&*s.id, &*s.updated_at, &*s.model, &*s.cwd])
        .collect();
    let mut widths = header.map(columns);
    for row in &rows {
        for (width, cell) in widths.iter_mut().zip(row) {
            *width = (*width).max(columns(cell));
        }
    }
    let mut out = String::new();
    for row in std::iter::once(&header).chain(&rows) {
        let mut line = String::new();
        for (i, cell) in row.iter().enumerate() {
            line.push_str(cell);
            if i + 1 < row.len() {
                line.push_str(&" ".repeat(widths[i] - columns(cell) + 2));
            }
        }
        out.push_str(&line);
        out.push('\n');
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn session(id: &str, model: &str, cwd: &str) -> SessionInfo {
        SessionInfo {
            id: id.into(),
            cwd: cwd.into(),
            model: model.into(),
            updated_at: "2026-01-01T00:00:00Z".into(),
        }
    }

    #[test]
    fn lists_sessions_in_aligned_columns() {
        let sessions = [
            session("s_10", "m-1", "/home/u/proj"),
            session("s_2", "a-longer-model", "/tmp"),
        ];

        assert_eq!(
            format(&sessions),
            "ID    UPDATED               MODEL           CWD\n\
             s_10  2026-01-01T00:00:00Z  m-1             /home/u/proj\n\
             s_2   2026-01-01T00:00:00Z  a-longer-model  /tmp\n"
        );
    }

    #[test]
    fn says_when_there_are_no_sessions() {
        assert_eq!(format(&[]), "no sessions\n");
    }
}
