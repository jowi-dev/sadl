//! The interactive chat TUI: a renderer and input device for one session.
//! It holds nothing beyond what it draws; the conversation lives in `sadld`.

pub mod app;
pub mod input;
pub mod transcript;
pub mod view;
pub mod wrap;
