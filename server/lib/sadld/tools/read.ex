defmodule Sadld.Tools.Read do
  @moduledoc """
  The `read` tool: returns a text file with numbered lines.

  Output is cut at `limit` lines (2000 by default), long lines at
  2000 characters and the whole output at about 50 KB. A cut
  output ends with a note giving the `offset` to continue from.
  """

  @behaviour Sadld.Tool

  alias Sadld.Tool

  @max_lines 2_000
  @max_line_length 2_000
  @max_bytes 50_000

  @impl true
  def spec do
    %{
      name: "read",
      description:
        "Read a text file. Returns its lines prefixed with line numbers. " <>
          "Large files are truncated; pass offset and limit to read further.",
      parameters: %{
        type: "object",
        properties: %{
          path: %{type: "string", description: "File path, relative to the working directory"},
          offset: %{type: "integer", minimum: 1, description: "First line to read (1-based)"},
          limit: %{type: "integer", minimum: 1, description: "Maximum number of lines to read"}
        },
        required: ["path"]
      }
    }
  end

  @impl true
  def run(args, cwd) do
    with {:ok, path} <- Tool.string(args, "path"),
         {:ok, offset} <- Tool.pos_integer(args, "offset", 1),
         {:ok, limit} <- Tool.pos_integer(args, "limit", @max_lines),
         path = Tool.resolve(path, cwd),
         {:ok, text} <- Tool.read_text(path) do
      render(path, lines(text), offset, limit)
    end
  end

  defp lines(""), do: []

  defp lines(text) do
    text |> String.trim_trailing("\n") |> String.split("\n")
  end

  defp render(path, lines, offset, limit) do
    total = length(lines)

    if offset > 1 and offset > total do
      {:error, "offset #{offset} is past the end of #{path} (#{total} #{plural(total)})"}
    else
      {shown, last} =
        lines
        |> Enum.drop(offset - 1)
        |> Enum.take(limit)
        |> Enum.with_index(offset)
        |> Enum.reduce_while({[], offset - 1}, &add_line/2)

      output = shown |> Enum.reverse() |> IO.iodata_to_binary()
      {:ok, output <> footer(offset, last, total)}
    end
  end

  defp add_line({line, number}, {acc, last}) do
    line = format_line(line, number)

    if IO.iodata_length(acc) + byte_size(line) > @max_bytes,
      do: {:halt, {acc, last}},
      else: {:cont, {[line | acc], number}}
  end

  defp format_line(line, number) do
    line =
      if String.length(line) > @max_line_length,
        do: String.slice(line, 0, @max_line_length) <> " [line truncated]",
        else: line

    String.pad_leading(Integer.to_string(number), 6) <> "\t" <> line <> "\n"
  end

  defp footer(_offset, total, total), do: ""

  defp footer(offset, last, total) do
    "\n[showing lines #{offset}-#{last} of #{total}; use offset=#{last + 1} to continue]\n"
  end

  defp plural(1), do: "line"
  defp plural(_count), do: "lines"
end
