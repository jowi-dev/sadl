defmodule Sadld.Test.StubPlugin do
  @moduledoc """
  A `Sadld.Plugin` for tests. Its ref is a keyword list of functions, each
  standing in for the callback of the same name; a missing one offers no
  tools, leaves hook output unchanged or ignores the event.

    * `:tools` - `(-> [Sadld.Tool.spec()])`
    * `:run_tool` - `(call, context -> {:ok | :error, String.t()})`
    * `:hook` - `(name, input, output -> output)`
    * `:event` - `(type, properties -> any())`
  """

  @behaviour Sadld.Plugin

  @impl true
  def tools(ref), do: Keyword.get(ref, :tools, fn -> [] end).()

  @impl true
  def run_tool(ref, call, context), do: Keyword.fetch!(ref, :run_tool).(call, context)

  @impl true
  def hook(ref, name, input, output) do
    case Keyword.fetch(ref, :hook) do
      {:ok, hook} -> hook.(name, input, output)
      :error -> output
    end
  end

  @impl true
  def event(ref, type, properties) do
    if event = ref[:event], do: event.(type, properties)
    :ok
  end
end
