//! Drawing the app: the transcript, the prompt editor (or a permission
//! prompt while a tool call waits for one) and a status line.
//!
//! The transcript is virtualized: blocks are wrapped newest first and only
//! until the visible window (plus the scroll offset) is filled, so drawing
//! cost follows the screen, not the length of the session.

use ratatui::Frame;
use ratatui::layout::{Constraint, Layout, Rect};
use ratatui::style::{Modifier, Style, Stylize};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;

use crate::tui::app::App;
use crate::tui::transcript::{Block, ToolBlock};
use crate::tui::wrap::{columns, wrap};

/// Most rows the prompt editor grows to before it scrolls.
const MAX_INPUT_ROWS: usize = 6;

const USER_PREFIX: &str = "› ";
const INPUT_PREFIX: &str = "> ";
const INDENT: &str = "  ";

/// Draws `app` into the whole frame. Clamps `app.scroll` to the transcript
/// and records the transcript's height in `app.page`.
pub fn draw(frame: &mut Frame, app: &mut App) {
    let area = frame.area();
    let input_width = usize::from(area.width).saturating_sub(INPUT_PREFIX.len());
    let input = app.input.layout(input_width);
    let input_rows = if app.asking.is_some() {
        1
    } else {
        input.lines.len().clamp(1, MAX_INPUT_ROWS)
    };
    let [transcript, rule, prompt, status] = Layout::vertical([
        Constraint::Min(0),
        Constraint::Length(1),
        Constraint::Length(input_rows as u16),
        Constraint::Length(1),
    ])
    .areas(area);

    draw_transcript(frame, app, transcript);
    frame.render_widget(
        Paragraph::new("─".repeat(usize::from(rule.width))).dim(),
        rule,
    );

    if let Some(call_id) = &app.asking {
        let line = permission_prompt(app, call_id, usize::from(prompt.width));
        frame.render_widget(Paragraph::new(line), prompt);
    } else {
        let offset = (input.cursor_row + 1).saturating_sub(input_rows);
        let lines: Vec<Line> = input
            .lines
            .into_iter()
            .enumerate()
            .skip(offset)
            .take(input_rows)
            .map(|(row, text)| {
                let prefix = if row == 0 { INPUT_PREFIX } else { INDENT };
                Line::from(vec![Span::raw(prefix).bold(), Span::raw(text)])
            })
            .collect();
        frame.render_widget(Paragraph::new(lines), prompt);
        frame.set_cursor_position((
            prompt.x + (INPUT_PREFIX.len() + input.cursor_col) as u16,
            prompt.y + (input.cursor_row - offset) as u16,
        ));
    }

    frame.render_widget(status_line(app, usize::from(status.width)), status);
}

/// Asks whether tool call `call_id` may run, naming it as its block does.
fn permission_prompt(app: &App, call_id: &str, width: usize) -> Line<'static> {
    const KEYS: &str = "  y / n";
    let tool = app.transcript.blocks().rev().find_map(|block| match block {
        Block::Tool(tool) if tool.call_id == call_id => Some(tool),
        _ => None,
    });
    let call = match tool {
        Some(tool) => format!("{} {}", tool.name, tool.args),
        None => "this tool call".to_string(),
    };
    let call = clip(
        &call,
        width.saturating_sub(columns("? allow ") + columns(KEYS)),
    );
    Line::from(vec![
        Span::raw("? ").bold(),
        Span::raw("allow "),
        Span::raw(call).bold(),
        Span::raw(KEYS).dim(),
    ])
}

fn draw_transcript(frame: &mut Frame, app: &mut App, area: Rect) {
    let height = usize::from(area.height);
    let width = usize::from(area.width);
    app.page = height;
    let (lines, reached_top) = transcript_lines(app, width, app.scroll.saturating_add(height));
    if reached_top {
        app.scroll = app.scroll.min(lines.len().saturating_sub(height));
    }
    let end = lines.len() - app.scroll.min(lines.len());
    let start = end.saturating_sub(height);
    let visible: Vec<Line> = lines.into_iter().skip(start).take(end - start).collect();
    frame.render_widget(Paragraph::new(visible), area);
}

/// The last `want` or more lines of the transcript, oldest first, and
/// whether they reach its top.
fn transcript_lines(app: &App, width: usize, want: usize) -> (Vec<Line<'static>>, bool) {
    let mut chunks = Vec::new();
    let mut count = 0;
    let mut reached_top = true;
    for (i, block) in app.transcript.blocks().rev().enumerate() {
        if count >= want {
            reached_top = false;
            break;
        }
        let mut lines = block_lines(block, width, app.expand_tools);
        if i > 0 {
            lines.push(Line::default());
        }
        count += lines.len();
        chunks.push(lines);
    }
    let dropped = app.transcript.dropped();
    if reached_top && dropped > 0 {
        chunks.push(vec![
            Line::from(format!("… {dropped} earlier blocks dropped")).dim(),
            Line::default(),
        ]);
    }
    (chunks.into_iter().rev().flatten().collect(), reached_top)
}

fn block_lines(block: &Block, width: usize, expand_tools: bool) -> Vec<Line<'static>> {
    match block {
        Block::User(text) => prefixed(text, width, USER_PREFIX, Style::new().bold()),
        Block::Assistant(text) => wrap(text.trim_end_matches('\n'), width)
            .into_iter()
            .map(Line::from)
            .collect(),
        Block::Notice(text) => prefixed(text, width, "· ", Style::new().italic().dim()),
        Block::Tool(tool) if expand_tools => expanded_tool(tool, width),
        Block::Tool(tool) => vec![collapsed_tool(tool, width)],
    }
}

/// `text` wrapped after `prefix` on the first line, with later lines
/// indented to match.
fn prefixed(text: &str, width: usize, prefix: &str, style: Style) -> Vec<Line<'static>> {
    let indent = " ".repeat(columns(prefix));
    wrap(text, width.saturating_sub(indent.len()))
        .into_iter()
        .enumerate()
        .map(|(i, line)| {
            let lead = if i == 0 {
                prefix.to_string()
            } else {
                indent.clone()
            };
            Line::from(vec![Span::raw(lead), Span::raw(line)]).style(style)
        })
        .collect()
}

fn collapsed_tool(tool: &ToolBlock, width: usize) -> Line<'static> {
    let mark = tool_mark(tool);
    let budget = width.saturating_sub(columns(&tool.name) + 6);
    let args = clip(&tool.args, budget);
    Line::from(vec![
        Span::raw("▸ ").dim(),
        Span::raw(tool.name.clone()).bold(),
        Span::raw(" "),
        Span::raw(args).dim(),
        Span::raw(" "),
        mark,
    ])
}

fn expanded_tool(tool: &ToolBlock, width: usize) -> Vec<Line<'static>> {
    let mut lines = vec![Line::from(vec![
        Span::raw("▾ ").dim(),
        Span::raw(tool.name.clone()).bold(),
        Span::raw(" "),
        tool_mark(tool),
    ])];
    let inner = width.saturating_sub(INDENT.len());
    lines.extend(
        wrap(&tool.args, inner)
            .into_iter()
            .map(|line| Line::from(format!("{INDENT}{line}")).dim()),
    );
    if let Some(result) = &tool.result {
        let style = if result.is_error {
            Style::new().red()
        } else {
            Style::new()
        };
        lines.extend(
            wrap(&result.output, inner)
                .into_iter()
                .map(|line| Line::from(format!("{INDENT}{line}")).style(style)),
        );
    }
    lines
}

/// ✓ for a tool that succeeded, ✗ for one that failed, … while it runs.
fn tool_mark(tool: &ToolBlock) -> Span<'static> {
    match &tool.result {
        None => Span::raw("…").dim(),
        Some(result) if result.is_error => Span::raw("✗").red(),
        Some(_) => Span::raw("✓").green(),
    }
}

/// The first line of `text`, cut to `budget` columns with an ellipsis.
fn clip(text: &str, budget: usize) -> String {
    let first = wrap(text, usize::MAX)
        .into_iter()
        .next()
        .unwrap_or_default();
    if columns(&first) <= budget {
        return first;
    }
    let mut clipped = String::new();
    let mut used = 0;
    for c in first.chars() {
        let c_width = columns(c.encode_utf8(&mut [0; 4]));
        if used + c_width + 1 > budget {
            break;
        }
        clipped.push(c);
        used += c_width;
    }
    clipped.push('…');
    clipped
}

fn status_line(app: &App, width: usize) -> Line<'static> {
    let mut left = match &app.session {
        Some(session) => format!(
            " {} · {} · {} in / {} out",
            session.model, session.id, app.usage.input_tokens, app.usage.output_tokens
        ),
        None => " connecting…".to_string(),
    };
    let mut right = match (&app.session, app.running, app.is_read_only()) {
        (None, _, _) => String::new(),
        (Some(_), _, _) if app.asking.is_some() => {
            "waiting for permission (Esc to cancel)".to_string()
        }
        (Some(_), true, true) => "read-only · running".to_string(),
        (Some(_), false, true) => "read-only · idle".to_string(),
        (Some(_), true, false) => "running (Esc to cancel)".to_string(),
        (Some(_), false, false) => "idle".to_string(),
    };
    if app.scroll > 0 {
        right = format!("scrolled {} · {right}", app.scroll);
    }
    right.push(' ');
    let room = width.saturating_sub(columns(&right));
    if columns(&left) > room {
        left = clip(&left, room);
    }
    let gap = room.saturating_sub(columns(&left));
    left.push_str(&" ".repeat(gap));
    Line::from(vec![Span::raw(left), Span::raw(right)])
        .style(Style::new().add_modifier(Modifier::REVERSED))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::{
        Event, JsonRpc, Notification, Outcome, PermissionRequest, Response, ServerMessage,
        StopReason, ToolCall, ToolResult, TurnDelta, TurnEnd, Usage,
    };
    use crate::start::Start;
    use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
    use ratatui::Terminal;
    use ratatui::backend::TestBackend;
    use serde_json::{Map, json};

    fn opened() -> App {
        let mut app = App::new(Start::Open {
            cwd: "/p".into(),
            model: None,
        });
        let open = app.open_call();
        app.sent(1, &open);
        app.on_message(ServerMessage::Response(Response {
            jsonrpc: JsonRpc::V2,
            id: Some(1),
            outcome: Outcome::Result(json!({
                "id": "s_1", "cwd": "/p", "model": "m-1",
                "updated_at": "2026-01-01T00:00:00Z"
            })),
        }));
        app
    }

    fn notify(app: &mut App, event: Event) {
        app.on_message(ServerMessage::Notification(Notification {
            jsonrpc: JsonRpc::V2,
            event,
        }));
    }

    fn delta(text: &str) -> Event {
        Event::TurnDelta(TurnDelta {
            session_id: "s_1".into(),
            turn_id: "t_1".into(),
            text: text.into(),
        })
    }

    fn type_text(app: &mut App, text: &str) {
        for c in text.chars() {
            app.on_key(KeyEvent::new(KeyCode::Char(c), KeyModifiers::NONE));
        }
    }

    /// Renders `app` at `width` x `height` and returns the screen's rows,
    /// right-trimmed.
    fn render(app: &mut App, width: u16, height: u16) -> Vec<String> {
        let mut terminal = Terminal::new(TestBackend::new(width, height)).unwrap();
        terminal.draw(|frame| draw(frame, app)).unwrap();
        let buffer = terminal.backend().buffer();
        buffer
            .content()
            .chunks(width as usize)
            .map(|row| {
                let line: String = row.iter().map(|cell| cell.symbol()).collect();
                line.trim_end().to_string()
            })
            .collect()
    }

    fn screen(rows: &[String]) -> String {
        rows.join("\n")
    }

    #[test]
    fn the_status_line_shows_model_session_and_usage() {
        let mut app = opened();
        type_text(&mut app, "hi");
        app.on_key(KeyEvent::new(KeyCode::Enter, KeyModifiers::NONE));
        notify(
            &mut app,
            Event::TurnEnd(TurnEnd {
                session_id: "s_1".into(),
                turn_id: "t_1".into(),
                stop_reason: StopReason::Completed,
                usage: Usage {
                    input_tokens: 1200,
                    output_tokens: 34,
                },
            }),
        );

        let rows = render(&mut app, 60, 8);

        let status = rows.last().unwrap();
        assert!(status.contains("m-1"), "{status}");
        assert!(status.contains("s_1"), "{status}");
        assert!(status.contains("1200 in"), "{status}");
        assert!(status.contains("34 out"), "{status}");
        assert!(status.contains("idle"), "{status}");
    }

    #[test]
    fn the_status_line_shows_a_running_turn_and_how_to_cancel() {
        let mut app = opened();
        type_text(&mut app, "hi");
        app.on_key(KeyEvent::new(KeyCode::Enter, KeyModifiers::NONE));

        let rows = render(&mut app, 60, 8);

        assert!(rows.last().unwrap().contains("running (Esc to cancel)"));
    }

    #[test]
    fn the_status_line_says_an_attached_view_is_read_only() {
        let mut app = App::new(Start::Resume { id: "s_1".into() }).read_only();
        let resume = app.open_call();
        app.sent(1, &resume);
        app.on_message(ServerMessage::Response(Response {
            jsonrpc: JsonRpc::V2,
            id: Some(1),
            outcome: Outcome::Result(json!({
                "id": "s_1", "cwd": "/p", "model": "m-1",
                "updated_at": "2026-01-01T00:00:00Z"
            })),
        }));

        let rows = render(&mut app, 60, 8);

        assert!(rows.last().unwrap().contains("read-only · idle"));
    }

    #[test]
    fn the_status_line_says_when_the_session_is_not_open_yet() {
        let mut app = App::new(Start::Open {
            cwd: "/p".into(),
            model: None,
        });

        let rows = render(&mut app, 60, 8);

        assert!(rows.last().unwrap().contains("connecting"));
    }

    #[test]
    fn streamed_text_appears_above_the_input() {
        let mut app = opened();
        type_text(&mut app, "hello");
        app.on_key(KeyEvent::new(KeyCode::Enter, KeyModifiers::NONE));
        notify(&mut app, delta("Hi "));
        notify(&mut app, delta("there"));
        type_text(&mut app, "next");

        let rows = render(&mut app, 30, 8);

        assert_eq!(rows[0], "› hello");
        assert_eq!(rows[1], "");
        assert_eq!(rows[2], "Hi there");
        assert!(rows.iter().any(|row| row == "> next"), "{}", screen(&rows));
    }

    #[test]
    fn trailing_newlines_do_not_add_blank_lines() {
        let mut app = opened();
        notify(&mut app, delta("done\n\n"));
        app.transcript.push_notice("next");

        let rows = render(&mut app, 30, 8);

        assert_eq!(rows[..3], ["done", "", "· next"]);
    }

    #[test]
    fn long_text_wraps_to_the_width() {
        let mut app = opened();
        notify(&mut app, delta("one two three four"));

        let rows = render(&mut app, 10, 8);

        assert_eq!(rows[..2], ["one two", "three four"]);
    }

    #[test]
    fn the_transcript_sticks_to_the_bottom() {
        let mut app = opened();
        let text: Vec<String> = (1..=20).map(|n| format!("line {n}")).collect();
        notify(&mut app, delta(&text.join("\n")));

        let rows = render(&mut app, 30, 8);

        let shown = screen(&rows);
        assert!(shown.contains("line 20"), "{shown}");
        assert!(!shown.contains("line 1\n"), "{shown}");
    }

    #[test]
    fn scrolling_shows_older_lines_and_stops_at_the_top() {
        let mut app = opened();
        let text: Vec<String> = (1..=20).map(|n| format!("line {n}")).collect();
        notify(&mut app, delta(&text.join("\n")));
        render(&mut app, 30, 8);

        app.scroll = 1000;
        let rows = render(&mut app, 30, 8);

        assert_eq!(rows[0], "line 1");
        assert_eq!(app.scroll, 20 - app.page);
        assert!(rows.last().unwrap().contains("scrolled"));
    }

    fn tool_session() -> App {
        let mut app = opened();
        let mut args = Map::new();
        args.insert("command".into(), json!("ls"));
        notify(
            &mut app,
            Event::ToolCall(ToolCall {
                session_id: "s_1".into(),
                turn_id: "t_1".into(),
                call_id: "c_1".into(),
                name: "bash".into(),
                args,
            }),
        );
        notify(
            &mut app,
            Event::ToolResult(ToolResult {
                session_id: "s_1".into(),
                turn_id: "t_1".into(),
                call_id: "c_1".into(),
                output: "a.txt\nb.txt".into(),
                is_error: false,
            }),
        );
        app
    }

    /// A running turn whose bash call `c_1` waits for permission.
    fn asking_session() -> App {
        let mut app = opened();
        type_text(&mut app, "draft");
        app.on_key(KeyEvent::new(KeyCode::Enter, KeyModifiers::NONE));
        let mut args = Map::new();
        args.insert("command".into(), json!("rm -rf build"));
        notify(
            &mut app,
            Event::ToolCall(ToolCall {
                session_id: "s_1".into(),
                turn_id: "t_1".into(),
                call_id: "c_1".into(),
                name: "bash".into(),
                args,
            }),
        );
        notify(
            &mut app,
            Event::PermissionRequest(PermissionRequest {
                session_id: "s_1".into(),
                turn_id: "t_1".into(),
                call_id: "c_1".into(),
            }),
        );
        app
    }

    #[test]
    fn a_permission_request_replaces_the_input_with_a_prompt() {
        let mut app = asking_session();

        let rows = render(&mut app, 60, 8);

        assert_eq!(
            rows[rows.len() - 2],
            r#"? allow bash {"command":"rm -rf build"}  y / n"#
        );
        assert!(
            rows.last()
                .unwrap()
                .contains("waiting for permission (Esc to cancel)")
        );
    }

    #[test]
    fn a_long_permission_prompt_is_clipped_to_the_width() {
        let mut app = asking_session();

        let rows = render(&mut app, 30, 8);

        let prompt = &rows[rows.len() - 2];
        assert!(prompt.ends_with("  y / n"), "{prompt}");
        assert!(prompt.contains("…"), "{prompt}");
    }

    #[test]
    fn tool_blocks_start_collapsed_to_one_line() {
        let mut app = tool_session();

        let rows = render(&mut app, 40, 8);

        assert_eq!(rows[0], r#"▸ bash {"command":"ls"} ✓"#);
        assert!(!screen(&rows).contains("a.txt"));
    }

    #[test]
    fn expanded_tool_blocks_show_their_output() {
        let mut app = tool_session();
        app.expand_tools = true;

        let rows = render(&mut app, 40, 10);

        assert_eq!(rows[0], "▾ bash ✓");
        assert_eq!(rows[1], r#"  {"command":"ls"}"#);
        assert_eq!(rows[2], "  a.txt");
        assert_eq!(rows[3], "  b.txt");
    }

    #[test]
    fn dropped_blocks_are_noted_at_the_top() {
        let mut app = opened();
        for n in 0..200_000 {
            notify(
                &mut app,
                Event::ToolCall(ToolCall {
                    session_id: "s_1".into(),
                    turn_id: "t_1".into(),
                    call_id: format!("c_{n}"),
                    name: "x".repeat(64),
                    args: Map::new(),
                }),
            );
        }
        assert!(app.transcript.dropped() > 0);
        app.scroll = usize::MAX;

        let rows = render(&mut app, 60, 8);

        assert!(
            rows[0].contains("earlier blocks dropped"),
            "{}",
            screen(&rows)
        );
    }

    #[test]
    fn the_input_grows_with_its_lines() {
        let mut app = opened();
        type_text(&mut app, "a");
        app.on_key(KeyEvent::new(KeyCode::Enter, KeyModifiers::ALT));
        type_text(&mut app, "b");

        let rows = render(&mut app, 20, 8);

        assert_eq!(rows[5], "> a");
        assert_eq!(rows[6], "  b");
    }
}
