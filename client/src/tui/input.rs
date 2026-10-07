//! The multiline prompt editor.

use unicode_width::UnicodeWidthChar;

/// The text being typed and the cursor in it.
#[derive(Debug, Default)]
pub struct Input {
    text: String,
    /// Byte offset of the cursor, always on a character boundary.
    cursor: usize,
}

impl Input {
    pub fn text(&self) -> &str {
        &self.text
    }

    pub fn is_blank(&self) -> bool {
        self.text.trim().is_empty()
    }

    /// Inserts `c` (which may be `'\n'`) before the cursor.
    pub fn insert(&mut self, c: char) {
        self.text.insert(self.cursor, c);
        self.cursor += c.len_utf8();
    }

    /// Removes the character before the cursor.
    pub fn backspace(&mut self) {
        if let Some(c) = self.text[..self.cursor].chars().next_back() {
            self.cursor -= c.len_utf8();
            self.text.remove(self.cursor);
        }
    }

    /// Removes the character under the cursor.
    pub fn delete(&mut self) {
        if self.cursor < self.text.len() {
            self.text.remove(self.cursor);
        }
    }

    pub fn left(&mut self) {
        if let Some(c) = self.text[..self.cursor].chars().next_back() {
            self.cursor -= c.len_utf8();
        }
    }

    pub fn right(&mut self) {
        if let Some(c) = self.text[self.cursor..].chars().next() {
            self.cursor += c.len_utf8();
        }
    }

    /// Moves to the start of the current line.
    pub fn home(&mut self) {
        self.cursor = self.line_start();
    }

    /// Moves to the end of the current line.
    pub fn end(&mut self) {
        self.cursor = self.line_end(self.cursor);
    }

    /// Moves to the line above, at the same column or its end if shorter.
    /// On the first line, moves to the start.
    pub fn up(&mut self) {
        let start = self.line_start();
        if start == 0 {
            self.cursor = 0;
            return;
        }
        let column = self.text[start..self.cursor].chars().count();
        let above = self.text[..start - 1].rfind('\n').map_or(0, |i| i + 1);
        self.cursor = self.at_column(above, column);
    }

    /// Moves to the line below, at the same column or its end if shorter.
    /// On the last line, moves to the end.
    pub fn down(&mut self) {
        let end = self.line_end(self.cursor);
        if end == self.text.len() {
            self.cursor = end;
            return;
        }
        let column = self.text[self.line_start()..self.cursor].chars().count();
        self.cursor = self.at_column(end + 1, column);
    }

    /// Returns the text and clears the editor.
    pub fn take(&mut self) -> String {
        self.cursor = 0;
        std::mem::take(&mut self.text)
    }

    /// Wraps the text at `width` columns, breaking anywhere, and finds the
    /// cursor's row and column in the result. A cursor that would sit just
    /// past the right edge moves to the start of a new row.
    pub fn layout(&self, width: usize) -> Layout {
        let width = width.max(1);
        let mut lines = vec![String::new()];
        let mut col = 0;
        let mut cursor = None;
        for (i, c) in self.text.char_indices() {
            if i == self.cursor {
                cursor = Some((lines.len() - 1, col));
            }
            if c == '\n' {
                lines.push(String::new());
                col = 0;
                continue;
            }
            let c_width = c.width().unwrap_or(0);
            if col + c_width > width && col > 0 {
                lines.push(String::new());
                col = 0;
                if i == self.cursor {
                    cursor = Some((lines.len() - 1, 0));
                }
            }
            if let Some(line) = lines.last_mut() {
                line.push(c);
            }
            col += c_width;
        }
        let (cursor_row, cursor_col) = cursor.unwrap_or_else(|| {
            if col >= width {
                lines.push(String::new());
                (lines.len() - 1, 0)
            } else {
                (lines.len() - 1, col)
            }
        });
        Layout {
            lines,
            cursor_row,
            cursor_col,
        }
    }

    fn line_start(&self) -> usize {
        self.text[..self.cursor].rfind('\n').map_or(0, |i| i + 1)
    }

    fn line_end(&self, from: usize) -> usize {
        self.text[from..]
            .find('\n')
            .map_or(self.text.len(), |i| from + i)
    }

    /// The byte offset `column` characters into the line starting at
    /// `start`, or that line's end.
    fn at_column(&self, start: usize, column: usize) -> usize {
        let end = self.line_end(start);
        self.text[start..end]
            .char_indices()
            .nth(column)
            .map_or(end, |(i, _)| start + i)
    }
}

/// The input wrapped to a width, and where the cursor lands in it.
#[derive(Debug, PartialEq, Eq)]
pub struct Layout {
    pub lines: Vec<String>,
    pub cursor_row: usize,
    pub cursor_col: usize,
}

#[cfg(test)]
mod tests {
    use super::*;

    fn typed(text: &str) -> Input {
        let mut input = Input::default();
        text.chars().for_each(|c| input.insert(c));
        input
    }

    /// The text with `|` marking the cursor.
    fn shown(input: &Input) -> String {
        let (before, after) = input.text().split_at(input.cursor);
        format!("{before}|{after}")
    }

    #[test]
    fn typing_inserts_at_the_cursor() {
        let mut input = typed("ac");
        input.left();
        input.insert('b');

        assert_eq!(shown(&input), "ab|c");
    }

    #[test]
    fn backspace_and_delete_remove_whole_characters() {
        let mut input = typed("aéz");
        input.left();
        input.backspace();
        assert_eq!(shown(&input), "a|z");

        input.delete();
        assert_eq!(shown(&input), "a|");

        input.delete();
        input.home();
        input.backspace();
        assert_eq!(shown(&input), "|a");
    }

    #[test]
    fn left_and_right_stop_at_the_ends() {
        let mut input = typed("ab");
        input.right();
        assert_eq!(shown(&input), "ab|");

        (0..5).for_each(|_| input.left());
        assert_eq!(shown(&input), "|ab");
    }

    #[test]
    fn home_and_end_move_within_the_current_line() {
        let mut input = typed("one\ntwo");
        input.left();
        input.home();
        assert_eq!(shown(&input), "one\n|two");

        input.left();
        input.home();
        assert_eq!(shown(&input), "|one\ntwo");

        input.end();
        assert_eq!(shown(&input), "one|\ntwo");
    }

    #[test]
    fn up_and_down_keep_the_column_where_they_can() {
        let mut input = typed("abcd\nx\nwxyz");
        input.up();
        assert_eq!(shown(&input), "abcd\nx|\nwxyz");

        input.up();
        assert_eq!(shown(&input), "a|bcd\nx\nwxyz");

        input.right();
        input.down();
        input.down();
        assert_eq!(shown(&input), "abcd\nx\nw|xyz");

        input.down();
        assert_eq!(shown(&input), "abcd\nx\nwxyz|");
    }

    #[test]
    fn take_returns_the_text_and_clears() {
        let mut input = typed("hi\nthere");

        assert_eq!(input.take(), "hi\nthere");
        assert_eq!(shown(&input), "|");
        assert!(input.is_blank());
    }

    #[test]
    fn layout_wraps_lines_and_places_the_cursor() {
        let mut input = typed("abcdef\ngh");
        input.up();
        input.right();
        input.right();

        assert_eq!(
            input.layout(4),
            Layout {
                lines: vec!["abcd".into(), "ef".into(), "gh".into()],
                cursor_row: 1,
                cursor_col: 0,
            }
        );
    }

    #[test]
    fn layout_moves_a_cursor_at_the_edge_to_the_next_row() {
        let input = typed("abcd");

        assert_eq!(
            input.layout(4),
            Layout {
                lines: vec!["abcd".into(), String::new()],
                cursor_row: 1,
                cursor_col: 0,
            }
        );
    }

    #[test]
    fn empty_input_lays_out_as_one_empty_line() {
        assert_eq!(
            Input::default().layout(4),
            Layout {
                lines: vec![String::new()],
                cursor_row: 0,
                cursor_col: 0,
            }
        );
    }
}
