defmodule Sadld.Test.StubProvider do
  @moduledoc """
  A `Sadld.Provider` for tests. Answers each request by calling the
  `:respond` function from its options.

  A one-argument `:respond` gets the message list, and its reply text is
  streamed as a single chunk. A two-argument one also gets the `:on_text`
  callback, to stream text however it likes, and a three-argument one also
  gets the options the provider was called with.
  """

  @behaviour Sadld.Provider

  @impl true
  def chat(messages, opts) do
    on_text = Keyword.fetch!(opts, :on_text)

    case Keyword.fetch!(opts, :respond) do
      respond when is_function(respond, 3) ->
        respond.(messages, on_text, opts)

      respond when is_function(respond, 2) ->
        respond.(messages, on_text)

      respond ->
        messages |> respond.() |> stream_text(on_text)
    end
  end

  defp stream_text({:ok, %{text: text}} = reply, on_text) do
    if text != "", do: on_text.(text)
    reply
  end

  defp stream_text(error, _on_text), do: error
end
