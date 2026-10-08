defmodule Sadld.Permissions do
  @moduledoc """
  A session's permission policy: whether each tool call the model makes
  runs (`:allow`), waits for a client to approve it (`:ask`), or fails
  without running (`:deny`).

  A policy is written as JSON, by default in `default_path/0`:

      {
        "default": "ask",
        "rules": [
          {"tool": "read", "action": "allow"},
          {"tool": "bash", "command": "git status*", "action": "allow"},
          {"tool": "bash", "command": "rm *", "action": "deny"}
        ]
      }

  Rules are tried in order and the first that matches decides; a call no
  rule matches gets `default`. A rule matches calls to the tool named by
  `tool`. A `bash` rule may also give `command`, a pattern the whole
  command must match, where `*` matches any text (newlines included) and
  every other character matches itself.

  Without a policy file every call is allowed, as in the MVP.
  """

  @actions %{"allow" => :allow, "ask" => :ask, "deny" => :deny}
  @actions_text ~s("allow", "ask", "deny")

  @type action :: :allow | :ask | :deny

  @opaque t :: %{default: action(), rules: [rule()]}

  @typep rule :: %{tool: String.t(), command: Regex.t() | nil, action: action()}

  @doc "The policy that allows every call."
  @spec allow_all() :: t()
  def allow_all, do: %{default: :allow, rules: []}

  @doc "The policy file: `permissions.json` in `Sadld.config_dir/0`."
  @spec default_path() :: Path.t()
  def default_path, do: Path.join(Sadld.config_dir(), "permissions.json")

  @doc """
  Reads the policy at `path`. A missing file gives `allow_all/0`; a file
  that is not a valid policy is an error naming the file and the problem.
  """
  @spec load(Path.t()) :: {:ok, t()} | {:error, String.t()}
  def load(path \\ default_path()) do
    case File.read(path) do
      {:ok, text} -> text |> decode() |> prefix_error(path)
      {:error, :enoent} -> {:ok, allow_all()}
      {:error, reason} -> {:error, "#{path}: #{:file.format_error(reason)}"}
    end
  end

  defp decode(text) do
    case JSON.decode(text) do
      {:ok, value} -> parse(value)
      {:error, _reason} -> {:error, "invalid JSON"}
    end
  end

  defp prefix_error({:error, message}, path), do: {:error, "#{path}: #{message}"}
  defp prefix_error(ok, _path), do: ok

  @doc """
  Builds a policy from its decoded JSON. Returns an error describing the
  first problem found.
  """
  @spec parse(term()) :: {:ok, t()} | {:error, String.t()}
  def parse(map) when is_map(map) do
    with {:ok, default} <- action(map["default"], "default"),
         {:ok, rules} <- rules(Map.get(map, "rules", [])) do
      {:ok, %{default: default, rules: rules}}
    end
  end

  def parse(_value), do: {:error, "the policy must be a JSON object"}

  defp rules(rules) when is_list(rules) do
    rules
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {rule, index}, {:ok, acc} ->
      case rule(rule) do
        {:ok, rule} -> {:cont, {:ok, [rule | acc]}}
        {:error, message} -> {:halt, {:error, "rule #{index}: #{message}"}}
      end
    end)
    |> case do
      {:ok, rules} -> {:ok, Enum.reverse(rules)}
      error -> error
    end
  end

  defp rules(_rules), do: {:error, "`rules` must be a list"}

  defp rule(rule) when is_map(rule) do
    with {:ok, tool} <- tool(rule),
         {:ok, command} <- command(rule, tool),
         {:ok, action} <- action(rule["action"], "action") do
      {:ok, %{tool: tool, command: command, action: action}}
    end
  end

  defp rule(_rule), do: {:error, "must be an object"}

  defp tool(%{"tool" => tool}) when is_binary(tool), do: {:ok, tool}
  defp tool(_rule), do: {:error, "`tool` must be a string"}

  defp command(rule, tool) do
    case Map.fetch(rule, "command") do
      :error -> {:ok, nil}
      {:ok, _pattern} when tool != "bash" -> {:error, "`command` only applies to the bash tool"}
      {:ok, pattern} when is_binary(pattern) -> {:ok, compile(pattern)}
      {:ok, _pattern} -> {:error, "`command` must be a string"}
    end
  end

  defp action(value, name) do
    case Map.fetch(@actions, value) do
      {:ok, action} -> {:ok, action}
      :error -> {:error, "`#{name}` must be one of #{@actions_text}"}
    end
  end

  # `*` matches any text; everything else is literal.
  defp compile(pattern) do
    source = pattern |> String.split("*") |> Enum.map_join(".*", &Regex.escape/1)
    Regex.compile!("\\A" <> source <> "\\z", "s")
  end

  @doc "Decides what happens to `call`, a `Sadld.Provider.tool_call()`."
  @spec check(t(), Sadld.Provider.tool_call()) :: action()
  def check(%{default: default, rules: rules}, call) do
    case Enum.find(rules, &matches?(&1, call)) do
      nil -> default
      rule -> rule.action
    end
  end

  defp matches?(%{tool: tool}, %{name: name}) when tool != name, do: false
  defp matches?(%{command: nil}, _call), do: true

  defp matches?(%{command: pattern}, %{args: %{"command" => command}}) when is_binary(command),
    do: Regex.match?(pattern, command)

  defp matches?(_rule, _call), do: false
end
