defmodule Sadld.Tools.Edit do
  @moduledoc """
  The `edit` tool: replaces one exact occurrence of `old` with `new` in a
  file. Fails, leaving the file untouched, when `old` is empty, missing or
  occurs more than once.
  """

  @behaviour Sadld.Tool

  alias Sadld.Tool

  @impl true
  def spec do
    %{
      name: "edit",
      description:
        "Replace exactly one occurrence of `old` with `new` in a file. " <>
          "`old` must match the file exactly, including whitespace, and must be unique; " <>
          "include surrounding lines to make it unique.",
      parameters: %{
        type: "object",
        properties: %{
          path: %{type: "string", description: "File path, relative to the working directory"},
          old: %{type: "string", description: "Exact text to replace"},
          new: %{type: "string", description: "Replacement text"}
        },
        required: ["path", "old", "new"]
      }
    }
  end

  @impl true
  def run(args, cwd) do
    with {:ok, path} <- Tool.string(args, "path"),
         {:ok, old} <- Tool.string(args, "old"),
         {:ok, new} <- Tool.string(args, "new"),
         :ok <- check_old(old),
         path = Tool.resolve(path, cwd),
         {:ok, text} <- Tool.read_text(path),
         {:ok, edited} <- replace(path, text, old, new),
         :ok <- write(path, edited) do
      {:ok, "Edited #{path}"}
    end
  end

  defp check_old(""), do: {:error, "`old` must not be empty"}
  defp check_old(_old), do: :ok

  defp replace(path, text, old, new) do
    case matches(text, old, 0, []) do
      [start] ->
        <<before::binary-size(start), _old::binary-size(byte_size(old)), rest::binary>> = text
        {:ok, before <> new <> rest}

      [] ->
        {:error, "`old` not found in #{path}"}

      starts ->
        {:error,
         "`old` occurs #{length(starts)} times in #{path}; " <>
           "include more surrounding text to make it unique"}
    end
  end

  # Start offsets of every match of `old`, overlapping ones included.
  defp matches(text, old, from, acc) do
    case :binary.match(text, old, scope: {from, byte_size(text) - from}) do
      {start, _length} -> matches(text, old, start + 1, [start | acc])
      :nomatch -> Enum.reverse(acc)
    end
  end

  defp write(path, text) do
    with {:error, reason} <- File.write(path, text), do: Tool.file_error(path, reason)
  end
end
