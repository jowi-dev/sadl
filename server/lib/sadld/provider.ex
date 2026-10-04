defmodule Sadld.Provider do
  @moduledoc """
  An LLM backend. A `Sadld.Session` calls `c:chat/2` once per model step of
  a turn, with the conversation so far, and acts on the reply: it emits the
  text and runs any tool calls, then calls again with their results until a
  reply has no tool calls.
  """

  @typedoc "A tool call the model asks for. `args` is the decoded argument object."
  @type tool_call :: %{id: String.t(), name: String.t(), args: map()}

  @typedoc """
  A conversation entry. Assistant entries carry the tool calls they made;
  each call is answered by a `:tool` entry with the same `call_id`.
  """
  @type message ::
          %{role: :user, content: String.t()}
          | %{role: :assistant, content: String.t(), tool_calls: [tool_call()]}
          | %{role: :tool, call_id: String.t(), content: String.t(), is_error: boolean()}

  @type usage :: %{input_tokens: non_neg_integer(), output_tokens: non_neg_integer()}

  @type response :: %{text: String.t(), tool_calls: [tool_call()], usage: usage()}

  @doc """
  Asks the model for its next reply to `messages`. `opts` are the options
  given alongside the module in the session's `:provider`.
  """
  @callback chat(messages :: [message()], opts :: keyword()) ::
              {:ok, response()} | {:error, term()}
end
