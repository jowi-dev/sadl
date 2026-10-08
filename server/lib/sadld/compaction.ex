defmodule Sadld.Compaction do
  @moduledoc """
  Keeps a conversation inside the model's context window by summarizing
  its older messages, pi-style.

  A compaction is a summary plus `first_kept`, the index of the first
  message kept verbatim. The stored messages never change: `context/2`
  builds what is sent to the provider, the summary (as a user message)
  followed by the messages from `first_kept` on. A later compaction
  summarizes the messages between the previous `first_kept` and its own,
  folding in the previous summary, so only the latest one matters.

  The cut is placed so that at least `:keep_recent_tokens` of the newest
  messages stay verbatim, and never between an assistant message and the
  results of its tool calls.

  Token counts here are estimates of about four characters per token,
  except where a session knows the provider's reported usage.

  ## Options

  Read from `config :sadld, Sadld.Compaction, ...`, overridden by those
  passed in:

    * `:context_window` - the model's context size in tokens
      (default 128_000)
    * `:reserve_tokens` - room kept free for the reply; compaction is
      `needed?/2` once less than this is left (default 16_384)
    * `:keep_recent_tokens` - the newest messages kept verbatim
      (default 20_000)
  """

  alias Sadld.Provider

  @type t :: Sadld.Store.compaction()

  @defaults [context_window: 128_000, reserve_tokens: 16_384, keep_recent_tokens: 20_000]

  # Tool output beyond this many characters is cut from the summary request,
  # so the request itself fits in the context window.
  @max_tool_output 2_000

  @system_prompt """
  You are a context summarization assistant. You read a conversation between \
  a user and an AI coding assistant and write a summary that another AI \
  assistant will use to continue the work. Do not continue the conversation \
  and do not answer any question in it. Only output the summary.
  """

  @instructions """
  Summarize the conversation above so the work can continue without it. Use \
  this format, keeping each section brief and concrete:

  ## Goal
  What the user is trying to accomplish.

  ## Constraints & Preferences
  Requirements and preferences the user stated.

  ## Progress
  What has been done, with exact file paths, function names and commands.

  ## Key Decisions
  Decisions made and why.

  ## Next Steps
  What remains to be done, in order.

  ## Critical Context
  Anything else needed to continue: error messages, values, open questions.
  """

  @doc "The compaction options: the defaults, then the app config, then `overrides`."
  @spec options(keyword()) :: keyword()
  def options(overrides \\ []) do
    @defaults
    |> Keyword.merge(Application.get_env(:sadld, __MODULE__, []))
    |> Keyword.merge(overrides)
  end

  @doc "Estimates the tokens of a message, a list of messages or a string."
  @spec estimate_tokens(Provider.message() | [Provider.message()] | String.t()) ::
          non_neg_integer()
  def estimate_tokens(messages) when is_list(messages),
    do: messages |> Enum.map(&estimate_tokens/1) |> Enum.sum()

  def estimate_tokens(text) when is_binary(text), do: div(String.length(text) + 3, 4)

  def estimate_tokens(%{role: :assistant, content: content, tool_calls: calls}) do
    calls = Enum.map_join(calls, fn call -> call.name <> Jason.encode!(call.args) end)
    estimate_tokens(content <> calls)
  end

  def estimate_tokens(%{content: content}), do: estimate_tokens(content)

  @doc "Whether a context of `tokens` leaves less than `:reserve_tokens` free."
  @spec needed?(non_neg_integer(), keyword()) :: boolean()
  def needed?(tokens, opts) do
    opts = options(opts)
    tokens > opts[:context_window] - opts[:reserve_tokens]
  end

  @doc """
  The index of the first message to keep so that at least
  `keep_recent_tokens` of the newest messages stay, never a tool result.
  `nil` when that leaves no message at or after `from` to summarize.
  """
  @spec cut_point([Provider.message()], non_neg_integer(), non_neg_integer()) ::
          non_neg_integer() | nil
  def cut_point(messages, from, keep_recent_tokens) do
    indexed = messages |> Enum.with_index() |> Enum.reverse()

    reached =
      Enum.reduce_while(indexed, 0, fn {message, index}, acc ->
        acc = acc + estimate_tokens(message)
        if acc >= keep_recent_tokens, do: {:halt, {:at, index}}, else: {:cont, acc}
      end)

    with {:at, index} <- reached,
         cut when cut > from <- valid_cut_at_or_before(messages, index) do
      cut
    else
      _no_cut -> nil
    end
  end

  defp valid_cut_at_or_before(messages, index) do
    messages
    |> Enum.take(index + 1)
    |> Enum.with_index()
    |> Enum.reverse()
    |> Enum.find_value(0, fn {message, i} -> if message.role != :tool, do: i end)
  end

  @doc "The messages sent to the provider: `messages` as `compaction` leaves them."
  @spec context([Provider.message()], t() | nil) :: [Provider.message()]
  def context(messages, nil), do: messages

  def context(messages, %{summary: summary, first_kept: first_kept}),
    do: [summary_message(summary) | Enum.drop(messages, first_kept)]

  defp summary_message(summary) do
    content = """
    The conversation history before this point was compacted into the following summary:

    <summary>
    #{summary}
    </summary>
    """

    %{role: :user, content: content}
  end

  @doc """
  Compacts `messages`, already compacted by `previous` (or `nil`), with the
  session's `provider`. Returns the new compaction and the usage of the
  summary request, or `:noop` when there is nothing to summarize.

  Takes the module options plus `force: true`, which summarizes every
  message when keeping `:keep_recent_tokens` would leave nothing to
  summarize, as a manual `/compact` does.
  """
  @spec compact([Provider.message()], t() | nil, {module(), keyword()}, keyword()) ::
          {:ok, t(), Provider.usage()} | :noop | {:error, term()}
  def compact(messages, previous, provider, opts \\ []) do
    from = if previous, do: previous.first_kept, else: 0
    cut = cut_point(messages, from, options(opts)[:keep_recent_tokens])

    cut =
      if cut == nil and Keyword.get(opts, :force, false) and length(messages) > from,
        do: length(messages),
        else: cut

    if cut do
      to_summarize = messages |> Enum.slice(from, cut - from)

      with {:ok, summary, usage} <-
             summarize(to_summarize, previous && previous.summary, provider) do
        {:ok, %{summary: summary, first_kept: cut}, usage}
      end
    else
      :noop
    end
  end

  @doc """
  Asks `provider` to summarize `messages`, folding in `previous_summary`
  when given. The conversation is sent as text in one user message, with
  no tools offered, so the model writes a summary rather than carrying on.
  """
  @spec summarize([Provider.message()], String.t() | nil, {module(), keyword()}) ::
          {:ok, String.t(), Provider.usage()} | {:error, term()}
  def summarize(messages, previous_summary, {provider, provider_opts}) do
    opts =
      Keyword.merge(provider_opts,
        system: @system_prompt,
        tools: [],
        on_text: fn _text -> :ok end
      )

    prompt = [%{role: :user, content: prompt(messages, previous_summary)}]

    case provider.chat(prompt, opts) do
      {:ok, %{text: text, usage: usage}} -> {:ok, String.trim(text), usage}
      {:error, reason} -> {:error, reason}
    end
  end

  defp prompt(messages, previous_summary) do
    previous =
      if previous_summary,
        do: "<previous-summary>\n#{previous_summary}\n</previous-summary>\n\n",
        else: ""

    conversation = Enum.map_join(messages, "\n\n", &serialize/1)

    update =
      if previous_summary,
        do: "Update the previous summary with the new conversation. ",
        else: ""

    previous <> "<conversation>\n#{conversation}\n</conversation>\n\n" <> update <> @instructions
  end

  defp serialize(%{role: :user, content: content}), do: "[User]: " <> content

  defp serialize(%{role: :assistant, content: content, tool_calls: calls}) do
    calls =
      Enum.map(calls, fn call -> "[Tool call]: #{call.name}(#{Jason.encode!(call.args)})" end)

    [if(content == "", do: [], else: ["[Assistant]: " <> content]) | calls]
    |> List.flatten()
    |> Enum.join("\n")
  end

  defp serialize(%{role: :tool, content: content, is_error: is_error}) do
    label = if is_error, do: "[Tool error]: ", else: "[Tool result]: "

    if String.length(content) > @max_tool_output,
      do: label <> String.slice(content, 0, @max_tool_output) <> "\n[... output truncated]",
      else: label <> content
  end
end
