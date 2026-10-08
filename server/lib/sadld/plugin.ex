defmodule Sadld.Plugin do
  @moduledoc """
  Something that extends a `Sadld.Session` from outside: offers the model
  extra tools, rewrites what the session sends the model, and hears about
  the session's lifecycle (ADR-0004). `Sadld.Sidecar` implements it for
  opencode plugins, so the hook names and the string-keyed maps passed to
  them follow opencode's plugin API.

  A session holds its plugins as `{module, ref}` pairs, `ref` being what
  the module needs to reach its plugin. The functions here apply a call to
  a whole list of them, in order.

  A session calls, from its turn task:

    * `"experimental.chat.system.transform"` with
      `%{"sessionID", "model" => %{"id"}}` and `%{"system" => [String.t()]}`
      before each model call. The parts are joined with blank lines.
    * `"chat.message"` with `%{"sessionID", "messageID"}` and
      `%{"message", "parts"}` when a turn starts. Text parts a plugin
      appends become user messages after the prompt.
    * `"tool.execute.after"` with `%{"tool", "sessionID", "callID", "args"}`
      and `%{"title", "output", "metadata"}` after each tool call. The
      `"output"` it leaves is what the model reads.

  and sends the events `session.created`, `session.status`, `session.idle`
  and `session.error` described in `docs/sidecar.md`.
  """

  @type t :: {module(), ref()}

  @type ref :: term()

  @typedoc "Where a plugin tool runs: the session, the turn and its cwd."
  @type tool_context :: %{session_id: String.t(), turn_id: String.t(), cwd: Path.t()}

  @doc "Returns the tools the plugin offers the model."
  @callback tools(ref()) :: [Sadld.Tool.spec()]

  @doc "Runs a call to one of the plugin's tools."
  @callback run_tool(ref(), Sadld.Provider.tool_call(), tool_context()) ::
              {:ok, String.t()} | {:error, String.t()}

  @doc """
  Calls hook `name` with `input` and returns `output` as the plugin leaves
  it, unchanged when the plugin has no such hook or it fails.
  """
  @callback hook(ref(), name :: String.t(), input :: map(), output :: map()) :: map()

  @doc "Tells the plugin about event `type`, without waiting for it."
  @callback event(ref(), type :: String.t(), properties :: map()) :: :ok

  @doc """
  Returns every plugin's tools, each paired with the plugin that runs it.
  A name already taken, by `taken` or an earlier plugin, is dropped.
  """
  @spec tools([t()], [String.t()]) :: [{Sadld.Tool.spec(), t()}]
  def tools(plugins, taken \\ []) do
    {tools, _names} =
      plugins
      |> Enum.flat_map(fn {module, ref} = plugin ->
        Enum.map(module.tools(ref), &{&1, plugin})
      end)
      |> Enum.flat_map_reduce(MapSet.new(taken), fn {spec, _plugin} = tool, names ->
        if MapSet.member?(names, spec.name),
          do: {[], names},
          else: {[tool], MapSet.put(names, spec.name)}
      end)

    tools
  end

  @doc "Passes `output` through hook `name` of each plugin in turn."
  @spec hook([t()], String.t(), map(), map()) :: map()
  def hook(plugins, name, input, output) do
    Enum.reduce(plugins, output, fn {module, ref}, output ->
      module.hook(ref, name, input, output)
    end)
  end

  @doc """
  Describes a session as opencode's `Session` object, from its stored info.
  sadld keeps no creation time apart from the store's, so `created` is the
  last update too.
  """
  @spec session(%{id: String.t(), cwd: Path.t(), updated_at: String.t() | DateTime.t()}) ::
          map()
  def session(%{id: id, cwd: cwd, updated_at: updated_at}) do
    updated = updated_at |> to_datetime() |> DateTime.to_unix(:millisecond)

    %{
      "id" => id,
      "title" => "",
      "directory" => cwd,
      "time" => %{"created" => updated, "updated" => updated}
    }
  end

  defp to_datetime(%DateTime{} = datetime), do: datetime

  defp to_datetime(string) do
    {:ok, datetime, _offset} = DateTime.from_iso8601(string)
    datetime
  end

  @doc "Sends event `type` to every plugin."
  @spec event([t()], String.t(), map()) :: :ok
  def event(plugins, type, properties) do
    Enum.each(plugins, fn {module, ref} -> module.event(ref, type, properties) end)
  end
end
