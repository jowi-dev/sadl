//! Which session a client shows: a new one, or one the server already has.

use crate::protocol::{Call, SessionIdParams, SessionOpenParams};

/// How a client gets its session.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Start {
    /// A new session whose tools run in `cwd`, with the server's default
    /// model unless `model` is given.
    Open { cwd: String, model: Option<String> },
    /// The persisted session `id`.
    Resume { id: String },
}

impl Start {
    /// The request that opens or resumes the session and subscribes the
    /// connection to it.
    pub fn call(&self) -> Call {
        match self {
            Self::Open { cwd, model } => Call::SessionOpen(SessionOpenParams {
                cwd: cwd.clone(),
                model: model.clone(),
            }),
            Self::Resume { id } => Call::SessionResume(SessionIdParams { id: id.clone() }),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn open_sends_session_open() {
        let start = Start::Open {
            cwd: "/p".into(),
            model: Some("m".into()),
        };

        assert_eq!(
            start.call(),
            Call::SessionOpen(SessionOpenParams {
                cwd: "/p".into(),
                model: Some("m".into()),
            })
        );
    }

    #[test]
    fn resume_sends_session_resume() {
        let start = Start::Resume { id: "s_1".into() };

        assert_eq!(
            start.call(),
            Call::SessionResume(SessionIdParams { id: "s_1".into() })
        );
    }
}
