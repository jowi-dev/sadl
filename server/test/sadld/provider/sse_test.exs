defmodule Sadld.Provider.SSETest do
  use ExUnit.Case, async: true

  alias Sadld.Provider.SSE

  defp feed(chunks) do
    Enum.reduce(chunks, {[], SSE.new()}, fn chunk, {events, sse} ->
      {new, sse} = SSE.parse(sse, chunk)
      {events ++ new, sse}
    end)
  end

  test "yields the data of each complete event" do
    assert {["one", "two"], _sse} = feed(["data: one\n\ndata: two\n\n"])
  end

  test "holds an incomplete event until the rest arrives" do
    assert {[], sse} = SSE.parse(SSE.new(), "data: {\"a\":")
    assert {["{\"a\":1}"], _sse} = SSE.parse(sse, "1}\n\n")
  end

  test "handles events split at any byte, including inside CRLF" do
    text = "data: one\r\n\r\ndata: two\r\n\r\n"

    for at <- 1..(byte_size(text) - 1) do
      <<a::binary-size(at), b::binary>> = text
      assert {["one", "two"], _sse} = feed([a, b])
    end
  end

  test "joins multi-line data with newlines" do
    assert {["a\nb"], _sse} = feed(["data: a\ndata: b\n\n"])
  end

  test "keeps data without a space after the colon intact" do
    assert {["x", " y"], _sse} = feed(["data:x\n\ndata:  y\n\n"])
  end

  test "ignores comments, other fields and events without data" do
    assert {["x"], _sse} = feed([": keep-alive\n\nevent: message\nid: 1\ndata: x\n\n"])
  end
end
