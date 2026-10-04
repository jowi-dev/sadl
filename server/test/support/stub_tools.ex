defmodule Sadld.Test.StubTools do
  @moduledoc """
  A `Sadld.ToolRunner` for tests. Runs each call with the `:run` function
  from its options, which receives the call and the session's cwd.
  """

  @behaviour Sadld.ToolRunner

  @impl true
  def run(call, cwd, opts), do: Keyword.fetch!(opts, :run).(call, cwd)
end
