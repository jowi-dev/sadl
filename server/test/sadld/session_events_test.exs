defmodule Sadld.SessionEventsTest do
  use ExUnit.Case, async: true

  alias Sadld.Protocol.Notification
  alias Sadld.SessionEvents

  defp session_id, do: "s_#{System.unique_integer([:positive])}"

  defp subscriber(id) do
    test_pid = self()

    pid =
      spawn_link(fn ->
        :ok = SessionEvents.subscribe(id)
        send(test_pid, :subscribed)

        receive do
          {:session_event, ^id, _} = event -> send(test_pid, {:got, self(), event})
        end
      end)

    assert_receive :subscribed
    pid
  end

  test "every subscriber to a session receives its broadcasts" do
    id = session_id()
    a = subscriber(id)
    b = subscriber(id)
    notification = %Notification{method: "turn.delta", params: %{text: "hi"}}

    :ok = SessionEvents.broadcast(id, notification)

    assert_receive {:got, ^a, {:session_event, ^id, ^notification}}
    assert_receive {:got, ^b, {:session_event, ^id, ^notification}}
  end

  test "broadcasts stay on their own session's topic" do
    id = session_id()
    :ok = SessionEvents.subscribe(id)

    :ok = SessionEvents.broadcast(session_id(), %Notification{method: "turn.delta", params: %{}})

    refute_receive {:session_event, _, _}
  end

  test "an unsubscribed process stops receiving broadcasts" do
    id = session_id()
    :ok = SessionEvents.subscribe(id)
    :ok = SessionEvents.unsubscribe(id)

    :ok = SessionEvents.broadcast(id, %Notification{method: "turn.delta", params: %{}})

    refute_receive {:session_event, _, _}
  end

  test "subscribing twice still delivers each broadcast once" do
    id = session_id()
    :ok = SessionEvents.subscribe(id)
    :ok = SessionEvents.subscribe(id)

    :ok = SessionEvents.broadcast(id, %Notification{method: "turn.delta", params: %{}})

    assert_receive {:session_event, ^id, _}
    refute_receive {:session_event, ^id, _}
  end

  test "broadcasting to a session nobody watches is fine" do
    assert SessionEvents.broadcast(session_id(), %Notification{method: "turn.delta", params: %{}}) ==
             :ok
  end
end
