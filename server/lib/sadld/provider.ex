defmodule Sadld.Provider do
  @moduledoc """
  An LLM backend. A `Sadld.Session` calls `c:chat/2` once per model step of
  a turn, with the conversation so far, and acts on the reply: it runs any
  tool calls, then calls again with their results until a reply has no
  tool calls.

  Reply text streams: the provider passes each chunk to the `:on_text`
  callback as it arrives, and the session forwards it as a `turn.delta`.
  The chunks concatenate to the reply's `text`.
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
  given alongside the module in the session's `:provider`, plus:

    * `:model` - the session's model name
    * `:on_text` - a `(String.t() -> any())` callback for each chunk of
      reply text, called in order before `c:chat/2` returns
    * `:system` - the system prompt, when the session has one
  """
  @callback chat(messages :: [message()], opts :: keyword()) ::
              {:ok, response()} | {:error, term()}
end
