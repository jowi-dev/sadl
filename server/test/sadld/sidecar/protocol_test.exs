defmodule Sadld.Sidecar.ProtocolTest do
  use ExUnit.Case, async: true

  alias Sadld.Sidecar.Protocol

  @fixtures_dir Path.expand("../../../../protocol/sidecar/fixtures", __DIR__)
  @fixture_name ~r/^(?<method>.+)\.(?<kind>request|response|notification)(\.[a-z0-9-]+)?\.json$/

  test "every fixture roundtrips losslessly" do
    names = File.ls!(@fixtures_dir)
    assert names != []

    for name <- names do
      %{"kind" => kind} =
        Regex.named_captures(@fixture_name, name) || flunk("#{name}: unrecognised fixture name")

      line = @fixtures_dir |> Path.join(name) |> File.read!()
      assert {:ok, message} = Protocol.decode(line), "#{name} failed to decode"
      assert Atom.to_string(elem(message, 0)) == kind, "#{name} decoded as #{inspect(message)}"
      assert JSON.decode!(Protocol.encode(message)) == JSON.decode!(line), "#{name} differs"
    end
  end

  test "decodes each kind of message" do
    assert Protocol.decode(~s({"jsonrpc":"2.0","id":1,"method":"hook","params":{"name":"x"}})) ==
             {:ok, {:request, 1, "hook", %{"name" => "x"}}}

    assert Protocol.decode(~s({"jsonrpc":"2.0","method":"event","params":{}})) ==
             {:ok, {:notification, "event", %{}}}

    assert Protocol.decode(~s({"jsonrpc":"2.0","id":2,"result":true})) ==
             {:ok, {:response, 2, {:ok, true}}}

    assert Protocol.decode(~s({"jsonrpc":"2.0","id":3,"error":{"code":-32601,"message":"no"}})) ==
             {:ok, {:response, 3, {:error, -32_601, "no"}}}
  end

  test "rejects lines that are not messages" do
    assert Protocol.decode("not json") == {:error, :invalid}
    assert Protocol.decode(~s({"jsonrpc":"2.0","id":1})) == {:error, :invalid}
    assert Protocol.decode(~s([1])) == {:error, :invalid}
  end

  test "encodes one line with no raw newline" do
    line = Protocol.encode({:request, 0, "hook", %{"text" => "a\nb"}})
    refute String.contains?(line, "\n")
  end
end
