defmodule Sadld.ProtocolTest do
  use ExUnit.Case, async: true

  alias Sadld.Protocol
  alias Sadld.Protocol.{Notification, Request, Response}

  @fixtures_dir Path.expand("../../../protocol/fixtures", __DIR__)
  @fixture_name ~r/^(?<method>.+)\.(?<kind>request|response|notification)(\.[a-z0-9-]+)?\.json$/

  defp roundtrip(name, original) do
    %{"method" => method, "kind" => kind} =
      Regex.named_captures(@fixture_name, name) || flunk("#{name}: unrecognised fixture name")

    decoded =
      case kind do
        "request" -> Protocol.decode_request(original)
        "response" -> Protocol.decode_response(original, method)
        "notification" -> Protocol.decode_notification(original)
      end

    assert {:ok, message} = decoded, "#{name} failed to decode: #{inspect(decoded)}"
    Protocol.to_map(message)
  end

  test "every fixture roundtrips losslessly" do
    names = File.ls!(@fixtures_dir)
    assert names != []

    for name <- names do
      original = @fixtures_dir |> Path.join(name) |> File.read!() |> JSON.decode!()
      assert roundtrip(name, original) == original, "#{name} did not roundtrip"
    end
  end

  test "version/0 is 0" do
    assert Protocol.version() == 0
  end

  test "decodes request params into atom-keyed maps" do
    map = %{
      "jsonrpc" => "2.0",
      "id" => 7,
      "method" => "session.open",
      "params" => %{"cwd" => "/tmp"}
    }

    assert {:ok, %Request{id: 7, method: "session.open", params: %{cwd: "/tmp"} = params}} =
             Protocol.decode_request(map)

    refute Map.has_key?(params, :model)
  end

  test "rejects a request whose params do not match its method" do
    map = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "session.send",
      "params" => %{"id" => "s_01"}
    }

    assert {:error, {:invalid_params, ["text"]}} = Protocol.decode_request(map)
  end

  test "rejects a wrongly typed nested field with its path" do
    map = %{
      "jsonrpc" => "2.0",
      "method" => "turn.end",
      "params" => %{
        "session_id" => "s",
        "turn_id" => "t",
        "stop_reason" => "completed",
        "usage" => %{"input_tokens" => 1, "output_tokens" => "2"}
      }
    }

    assert {:error, {:invalid_params, ["usage", "output_tokens"]}} =
             Protocol.decode_notification(map)
  end

  test "rejects an unknown stop_reason" do
    map = %{
      "jsonrpc" => "2.0",
      "method" => "turn.end",
      "params" => %{
        "session_id" => "s",
        "turn_id" => "t",
        "stop_reason" => "bored",
        "usage" => %{"input_tokens" => 1, "output_tokens" => 2}
      }
    }

    assert {:error, {:invalid_params, ["stop_reason"]}} = Protocol.decode_notification(map)
  end

  test "rejects an unknown method" do
    map = %{"jsonrpc" => "2.0", "id" => 1, "method" => "session.nope", "params" => %{}}
    assert {:error, :method_not_found} = Protocol.decode_request(map)
  end

  test "rejects a message without jsonrpc 2.0" do
    map = %{"jsonrpc" => "1.0", "id" => 1, "method" => "session.list", "params" => %{}}
    assert {:error, :invalid_request} = Protocol.decode_request(map)
  end

  test "encodes an error response" do
    response = %Response{id: 3, error: %{code: -32_003, message: "session busy"}}

    assert Protocol.to_map(response) == %{
             "jsonrpc" => "2.0",
             "id" => 3,
             "error" => %{"code" => -32_003, "message" => "session busy"}
           }
  end

  test "encodes a notification" do
    notification = %Notification{
      method: "turn.delta",
      params: %{session_id: "s", turn_id: "t", text: "hi"}
    }

    assert Protocol.to_map(notification) == %{
             "jsonrpc" => "2.0",
             "method" => "turn.delta",
             "params" => %{"session_id" => "s", "turn_id" => "t", "text" => "hi"}
           }
  end
end
