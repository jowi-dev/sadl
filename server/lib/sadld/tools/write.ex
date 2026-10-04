defmodule Sadld.Tools.Write do
  @moduledoc """
  The `write` tool: creates or overwrites a file with the given content,
  creating missing parent directories.
  """

  @behaviour Sadld.Tool

  alias Sadld.Tool

  @impl true
  def spec do
    %{
      name: "write",
      description:
        "Write content to a file, replacing it if it exists. " <>
          "Missing parent directories are created.",
      parameters: %{
        type: "object",
        properties: %{
          path: %{type: "string", description: "File path, relative to the working directory"},
          content: %{type: "string", description: "The complete new file content"}
        },
        required: ["path", "content"]
      }
    }
  end

  @impl true
  def run(args, cwd) do
    with {:ok, path} <- Tool.string(args, "path"),
         {:ok, content} <- Tool.string(args, "content"),
         path = Tool.resolve(path, cwd),
         :ok <- write(path, content) do
      {:ok, "Wrote #{byte_size(content)} bytes to #{path}"}
    end
  end

  defp write(path, content) do
    dir = Path.dirname(path)

    with {:mkdir, :ok} <- {:mkdir, File.mkdir_p(dir)},
         :ok <- File.write(path, content) do
      :ok
    else
      {:mkdir, {:error, reason}} -> Tool.file_error(dir, reason)
      {:error, reason} -> Tool.file_error(path, reason)
    end
  end
end
