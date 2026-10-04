defmodule Sadld.Provider.SSE do
  @moduledoc """
  An incremental decoder for `text/event-stream` bodies. Feed it the body
  in chunks as they arrive, split anywhere; it returns the `data` of each
  event once the event is complete.

  Only `data` fields matter to the providers, so other fields, comments and
  events without data are dropped. Lines may end in LF or CRLF.
  """

  @opaque t :: String.t()

  @doc "Returns a decoder that has seen nothing yet."
  @spec new() :: t()
  def new, do: ""

  @doc """
  Feeds `chunk` to the decoder. Returns the data of the events it
  completed, oldest first, and the decoder to feed the next chunk to.
  """
  @spec parse(t(), String.t()) :: {[String.t()], t()}
  def parse(buffer, chunk) do
    {events, [rest]} =
      (buffer <> chunk)
      |> String.replace("\r\n", "\n")
      |> String.split("\n\n")
      |> Enum.split(-1)

    {Enum.flat_map(events, &event_data/1), rest}
  end

  defp event_data(event) do
    case for "data:" <> value <- String.split(event, "\n"), do: strip_space(value) do
      [] -> []
      lines -> [Enum.join(lines, "\n")]
    end
  end

  defp strip_space(" " <> value), do: value
  defp strip_space(value), do: value
end
