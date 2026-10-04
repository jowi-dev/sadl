defmodule Sadld.Tools do
  @moduledoc """
  The built-in tools: `read`, `write` and `edit`. A `Sadld.ToolRunner` that
  dispatches each call to the `Sadld.Tool` of the same name, and the source
  of the tool specs the provider shows the model.

  Every failure, including an unknown tool or arguments that are not an
  object, comes back as `{:error, message}` for the model to read.
  """

  @behaviour Sadld.ToolRunner

  @tools [Sadld.Tools.Read, Sadld.Tools.Write, Sadld.Tools.Edit]

  @doc "Returns the spec of every tool, in a stable order."
  @spec specs() :: [Sadld.Tool.spec()]
  def specs, do: Enum.map(@tools, & &1.spec())

  @impl true
  def run(%{name: name, args: args}, cwd, _opts) do
    case Enum.find(@tools, &(&1.spec().name == name)) do
      nil -> {:error, "unknown tool #{inspect(name)}"}
      _tool when not is_map(args) -> {:error, "arguments to #{name} must be a JSON object"}
      tool -> tool.run(args, cwd)
    end
  end
end
