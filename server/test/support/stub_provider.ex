defmodule Sadld.Test.StubProvider do
  @moduledoc """
  A `Sadld.Provider` for tests. Answers each request by calling the
  `:respond` function from its options with the message list.
  """

  @behaviour Sadld.Provider

  @impl true
  def chat(messages, opts), do: Keyword.fetch!(opts, :respond).(messages)
end
