//! The scrollback the TUI draws: user prompts, streamed assistant text, tool
//! calls with their results, and notices. It is rebuilt from notifications as
//! they arrive and capped in size, so a long session cannot grow the client
//! without bound.

use std::collections::VecDeque;

use serde_json::Value;

use crate::protocol::{Event, StopReason};

/// One drawable item in the scrollback.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Block {
    User(String),
    Assistant(String),
    Tool(ToolBlock),
    /// A status message from the client itself, such as an error.
    Notice(String),
}

/// A tool call and, once it has arrived, its result.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ToolBlock {
    pub call_id: String,
    pub name: String,
    /// The arguments as compact JSON.
    pub args: String,
    pub result: Option<ToolOutcome>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ToolOutcome {
    pub output: String,
    pub is_error: bool,
}

/// Bytes of one tool's output kept for display; the rest is cut off.
pub const MAX_TOOL_OUTPUT: usize = 64 * 1024;

/// The scrollback, oldest block first.
#[derive(Debug)]
pub struct Transcript {
    blocks: VecDeque<Block>,
    bytes: usize,
    max_bytes: usize,
    dropped: usize,
}

impl Transcript {
    /// An empty transcript that keeps about `max_bytes` of text, dropping
    /// the oldest blocks beyond that. The newest block is always kept.
    pub fn new(max_bytes: usize) -> Self {
        Self {
            blocks: VecDeque::new(),
            bytes: 0,
            max_bytes,
            dropped: 0,
        }
    }

    pub fn push_user(&mut self, text: &str) {
        self.push(Block::User(text.to_string()));
    }

    pub fn push_notice(&mut self, text: &str) {
        self.push(Block::Notice(text.to_string()));
    }

    /// Draws a session notification into the scrollback.
    pub fn apply(&mut self, event: &Event) {
        match event {
            Event::TurnDelta(delta) => match self.blocks.back_mut() {
                Some(Block::Assistant(text)) => {
                    text.push_str(&delta.text);
                    self.bytes += delta.text.len();
                    self.evict();
                }
                _ => self.push(Block::Assistant(delta.text.clone())),
            },
            Event::ToolCall(call) => self.push(Block::Tool(ToolBlock {
                call_id: call.call_id.clone(),
                name: call.name.clone(),
                args: Value::Object(call.args.clone()).to_string(),
                result: None,
            })),
            Event::ToolResult(result) => {
                let tool = self.blocks.iter_mut().rev().find_map(|block| match block {
                    Block::Tool(tool) if tool.call_id == result.call_id => Some(tool),
                    _ => None,
                });
                if let Some(tool) = tool {
                    let output = truncate(&result.output, MAX_TOOL_OUTPUT);
                    self.bytes += output.len();
                    tool.result = Some(ToolOutcome {
                        output,
                        is_error: result.is_error,
                    });
                    self.evict();
                }
            }
            Event::TurnEnd(end) => {
                if end.stop_reason == StopReason::Cancelled {
                    self.push_notice("turn cancelled");
                }
            }
            Event::Error(error) => {
                self.push_notice(&format!("error {}: {}", error.code, error.message));
            }
            // The app shows the prompt; the tool block already names the call.
            Event::PermissionRequest(_) => {}
        }
    }

    /// The blocks still kept, oldest first.
    pub fn blocks(&self) -> impl DoubleEndedIterator<Item = &Block> + ExactSizeIterator {
        self.blocks.iter()
    }

    /// How many blocks have been dropped off the front to stay under the cap.
    pub fn dropped(&self) -> usize {
        self.dropped
    }

    /// Bytes of text currently kept.
    pub fn bytes(&self) -> usize {
        self.bytes
    }

    fn push(&mut self, block: Block) {
        self.bytes += block_bytes(&block);
        self.blocks.push_back(block);
        self.evict();
    }

    fn evict(&mut self) {
        while self.bytes > self.max_bytes && self.blocks.len() > 1 {
            if let Some(block) = self.blocks.pop_front() {
                self.bytes -= block_bytes(&block);
                self.dropped += 1;
            }
        }
    }
}

fn block_bytes(block: &Block) -> usize {
    match block {
        Block::User(text) | Block::Assistant(text) | Block::Notice(text) => text.len(),
        Block::Tool(tool) => {
            tool.call_id.len()
                + tool.name.len()
                + tool.args.len()
                + tool.result.as_ref().map_or(0, |result| result.output.len())
        }
    }
}

/// The first `max` bytes of `text` (backed off to a character boundary),
/// with a note of how much was cut.
fn truncate(text: &str, max: usize) -> String {
    if text.len() <= max {
        return text.to_string();
    }
    let mut end = max;
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    format!("{}\n… {} more bytes", &text[..end], text.len() - end)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::{
        SessionError, StopReason, ToolCall, ToolResult, TurnDelta, TurnEnd, Usage,
    };
    use serde_json::{Map, json};

    fn delta(text: &str) -> Event {
        Event::TurnDelta(TurnDelta {
            session_id: "s_1".into(),
            turn_id: "t_1".into(),
            text: text.into(),
        })
    }

    fn call(call_id: &str, name: &str) -> Event {
        let mut args = Map::new();
        args.insert("command".into(), json!("ls"));
        Event::ToolCall(ToolCall {
            session_id: "s_1".into(),
            turn_id: "t_1".into(),
            call_id: call_id.into(),
            name: name.into(),
            args,
        })
    }

    fn result(call_id: &str, output: &str, is_error: bool) -> Event {
        Event::ToolResult(ToolResult {
            session_id: "s_1".into(),
            turn_id: "t_1".into(),
            call_id: call_id.into(),
            output: output.into(),
            is_error,
        })
    }

    fn end(stop_reason: StopReason) -> Event {
        Event::TurnEnd(TurnEnd {
            session_id: "s_1".into(),
            turn_id: "t_1".into(),
            stop_reason,
            usage: Usage {
                input_tokens: 1,
                output_tokens: 1,
            },
        })
    }

    fn blocks(transcript: &Transcript) -> Vec<Block> {
        transcript.blocks().cloned().collect()
    }

    #[test]
    fn deltas_stream_into_one_assistant_block() {
        let mut transcript = Transcript::new(1024);
        transcript.push_user("hi");
        transcript.apply(&delta("Hel"));
        transcript.apply(&delta("lo"));

        assert_eq!(
            blocks(&transcript),
            [Block::User("hi".into()), Block::Assistant("Hello".into())]
        );
    }

    #[test]
    fn text_after_a_tool_call_starts_a_new_assistant_block() {
        let mut transcript = Transcript::new(1024);
        transcript.apply(&delta("Looking"));
        transcript.apply(&call("c_1", "bash"));
        transcript.apply(&result("c_1", "a.txt", false));
        transcript.apply(&delta("Done"));

        assert_eq!(
            blocks(&transcript),
            [
                Block::Assistant("Looking".into()),
                Block::Tool(ToolBlock {
                    call_id: "c_1".into(),
                    name: "bash".into(),
                    args: r#"{"command":"ls"}"#.into(),
                    result: Some(ToolOutcome {
                        output: "a.txt".into(),
                        is_error: false,
                    }),
                }),
                Block::Assistant("Done".into()),
            ]
        );
    }

    #[test]
    fn a_result_finds_its_call_by_id() {
        let mut transcript = Transcript::new(1024);
        transcript.apply(&call("c_1", "read"));
        transcript.apply(&call("c_2", "bash"));
        transcript.apply(&result("c_1", "boom", true));

        let first = match &blocks(&transcript)[0] {
            Block::Tool(tool) => tool.result.clone(),
            other => panic!("expected a tool block, got {other:?}"),
        };
        assert_eq!(
            first,
            Some(ToolOutcome {
                output: "boom".into(),
                is_error: true,
            })
        );
    }

    #[test]
    fn a_result_for_an_unknown_call_is_ignored() {
        let mut transcript = Transcript::new(1024);
        transcript.apply(&result("c_9", "lost", false));

        assert_eq!(blocks(&transcript), []);
    }

    #[test]
    fn errors_and_cancelled_turns_become_notices() {
        let mut transcript = Transcript::new(1024);
        transcript.apply(&Event::Error(SessionError {
            session_id: "s_1".into(),
            code: -32010,
            message: "provider down".into(),
        }));
        transcript.apply(&end(StopReason::Error));
        transcript.apply(&end(StopReason::Cancelled));
        transcript.apply(&end(StopReason::Completed));

        assert_eq!(
            blocks(&transcript),
            [
                Block::Notice("error -32010: provider down".into()),
                Block::Notice("turn cancelled".into()),
            ]
        );
    }

    #[test]
    fn drops_the_oldest_blocks_past_the_byte_cap() {
        let mut transcript = Transcript::new(10);
        transcript.push_user("aaaa");
        transcript.push_user("bbbb");
        transcript.push_user("cccc");

        assert_eq!(
            blocks(&transcript),
            [Block::User("bbbb".into()), Block::User("cccc".into())]
        );
        assert_eq!(transcript.dropped(), 1);
        assert_eq!(transcript.bytes(), 8);
    }

    #[test]
    fn streaming_past_the_cap_drops_older_blocks() {
        let mut transcript = Transcript::new(10);
        transcript.push_user("aaaa");
        transcript.apply(&delta("bbbb"));
        transcript.apply(&delta("cccc"));

        assert_eq!(blocks(&transcript), [Block::Assistant("bbbbcccc".into())]);
    }

    #[test]
    fn keeps_the_newest_block_even_when_it_alone_exceeds_the_cap() {
        let mut transcript = Transcript::new(4);
        transcript.push_user("too long");

        assert_eq!(blocks(&transcript), [Block::User("too long".into())]);
    }

    #[test]
    fn truncates_huge_tool_output() {
        let mut transcript = Transcript::new(1 << 20);
        transcript.apply(&call("c_1", "bash"));
        let output = "x".repeat(MAX_TOOL_OUTPUT + 100);
        transcript.apply(&result("c_1", &output, false));

        let Block::Tool(tool) = &blocks(&transcript)[0] else {
            panic!("expected a tool block");
        };
        let kept = &tool.result.as_ref().unwrap().output;
        assert!(kept.starts_with(&"x".repeat(MAX_TOOL_OUTPUT)));
        assert!(kept.ends_with("… 100 more bytes"));
    }
}
