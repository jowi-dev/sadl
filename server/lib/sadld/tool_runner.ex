defmodule Sadld.ToolRunner do
  @moduledoc """
  Executes the tool calls a model makes during a `Sadld.Session` turn.
  """

  @doc """
  Runs `call` in the session's working directory `cwd`. `opts` are the
  options given alongside the module in the session's `:tools`.

  Returns the tool's output, or `{:error, output}` describing a failure.
  A failure is reported to the model, not raised.
  """
  @callback run(call :: Sadld.Provider.tool_call(), cwd :: String.t(), opts :: keyword()) ::
              {:ok, String.t()} | {:error, String.t()}
end
