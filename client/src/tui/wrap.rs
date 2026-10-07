//! Soft-wrapping text to a terminal width.

use unicode_width::UnicodeWidthChar;

/// Columns a tab expands to.
const TAB: &str = "    ";

/// Wraps `text` into lines of at most `width` display columns.
///
/// Lines break between words where they can and inside a word only when it
/// is wider than a whole line. Hard line breaks are kept and leading
/// indentation is preserved. Tabs expand to four spaces and other control
/// characters are dropped, so escape sequences in tool output cannot reach
/// the terminal. A character wider than `width` still gets a line of its
/// own, so the result is never empty.
pub fn wrap(text: &str, width: usize) -> Vec<String> {
    let width = width.max(1);
    let mut lines = Vec::new();
    for paragraph in text.split('\n') {
        wrap_paragraph(&sanitize(paragraph), width, &mut lines);
    }
    lines
}

/// Display columns of `text`, counting control characters as zero.
pub fn columns(text: &str) -> usize {
    text.chars().map(char_columns).sum()
}

fn char_columns(c: char) -> usize {
    c.width().unwrap_or(0)
}

fn sanitize(paragraph: &str) -> String {
    let mut clean = String::with_capacity(paragraph.len());
    for c in paragraph.chars() {
        match c {
            '\t' => clean.push_str(TAB),
            c if c.is_control() => {}
            c => clean.push(c),
        }
    }
    clean
}

fn wrap_paragraph(paragraph: &str, width: usize, lines: &mut Vec<String>) {
    let mut line = String::new();
    let mut used = 0;
    for token in tokens(paragraph) {
        let token_width = columns(token);
        if used + token_width <= width {
            line.push_str(token);
            used += token_width;
        } else if token.starts_with(' ') {
            lines.push(take_line(&mut line, &mut used));
        } else {
            if used > 0 {
                lines.push(take_line(&mut line, &mut used));
            }
            for c in token.chars() {
                let c_width = char_columns(c);
                if used + c_width > width && used > 0 {
                    lines.push(take_line(&mut line, &mut used));
                }
                line.push(c);
                used += c_width;
            }
        }
    }
    lines.push(line);
}

/// Splits `paragraph` into alternating runs of spaces and non-spaces.
fn tokens(paragraph: &str) -> impl Iterator<Item = &str> {
    let mut rest = paragraph;
    std::iter::from_fn(move || {
        let first = rest.chars().next()?;
        let is_space = first == ' ';
        let end = rest
            .find(|c: char| (c == ' ') != is_space)
            .unwrap_or(rest.len());
        let (token, tail) = rest.split_at(end);
        rest = tail;
        Some(token)
    })
}

/// Ends the current line, dropping the spaces it broke at.
fn take_line(line: &mut String, used: &mut usize) -> String {
    *used = 0;
    let mut taken = std::mem::take(line);
    taken.truncate(taken.trim_end_matches(' ').len());
    taken
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn short_text_is_one_line() {
        assert_eq!(wrap("hello world", 20), ["hello world"]);
    }

    #[test]
    fn breaks_between_words() {
        assert_eq!(
            wrap("hello brave new world", 11),
            ["hello brave", "new world"]
        );
    }

    #[test]
    fn splits_a_word_longer_than_the_width() {
        assert_eq!(wrap("abcdefghij", 4), ["abcd", "efgh", "ij"]);
    }

    #[test]
    fn keeps_hard_line_breaks_and_blank_lines() {
        assert_eq!(wrap("a\n\nb", 10), ["a", "", "b"]);
    }

    #[test]
    fn empty_text_is_one_empty_line() {
        assert_eq!(wrap("", 10), [""]);
    }

    #[test]
    fn keeps_leading_indentation() {
        assert_eq!(wrap("    let x = 1;", 20), ["    let x = 1;"]);
    }

    #[test]
    fn expands_tabs_and_drops_control_characters() {
        assert_eq!(wrap("\tx\r\u{1b}[31my", 20), ["    x[31my"]);
    }

    #[test]
    fn counts_wide_characters_as_two_columns() {
        assert_eq!(wrap("日本語", 4), ["日本", "語"]);
    }

    #[test]
    fn a_zero_width_still_makes_progress() {
        assert_eq!(wrap("ab", 0), ["a", "b"]);
    }
}
