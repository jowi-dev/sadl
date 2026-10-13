defmodule Sadld.StoreTest do
  use ExUnit.Case, async: true

  alias Sadld.Store

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    path = Path.join([tmp_dir, "nested", "sadl.db"])
    store = start_supervised!({Store, path: path, name: nil})
    %{store: store, path: path}
  end

  defp create(store, id, cwd \\ "/home/u/proj") do
    {:ok, info} = Store.create_session(store, %{id: id, cwd: cwd, model: "m"})
    info
  end

  defp create_child(store, id, parent_id) do
    {:ok, info} =
      Store.create_session(store, %{id: id, cwd: "/home/u/proj", model: "m", parent_id: parent_id})

    info
  end

  test "create_session stores a session and returns its info", %{store: store} do
    info = create(store, "s_1")

    assert %{id: "s_1", cwd: "/home/u/proj", model: "m", parent_id: nil, updated_at: updated_at} =
             info

    assert {:ok, %DateTime{utc_offset: 0}, 0} = DateTime.from_iso8601(updated_at)
    assert Store.fetch_session(store, "s_1") == {:ok, info}
  end

  test "fetch_session on an unknown id is :not_found", %{store: store} do
    assert Store.fetch_session(store, "missing") == {:error, :not_found}
  end

  test "messages round-trip in order, tool calls and results included", %{store: store} do
    create(store, "s_1")
    call = %{id: "call_1", name: "read", args: %{"path" => "a.txt", "limit" => 3}}

    first = [%{role: :user, content: "read a.txt"}]

    second = [
      %{role: :assistant, content: "", tool_calls: [call]},
      %{role: :tool, call_id: "call_1", content: "contents", is_error: false},
      %{role: :assistant, content: "done", tool_calls: []}
    ]

    assert Store.append_messages(store, "s_1", first) == :ok
    assert Store.append_messages(store, "s_1", second) == :ok

    assert Store.messages(store, "s_1") == first ++ second
    assert Store.messages(store, "missing") == []
  end

  test "a synthetic user message keeps its mark", %{store: store} do
    create(store, "s_1")
    messages = [%{role: :user, content: "hi"}, %{role: :user, content: "note", synthetic: true}]

    :ok = Store.append_messages(store, "s_1", messages)

    assert Store.messages(store, "s_1") == messages
  end

  test "list_sessions puts the most recently updated first", %{store: store} do
    create(store, "s_1")
    create(store, "s_2")
    assert Enum.map(Store.list_sessions(store), & &1.id) == ["s_2", "s_1"]

    :ok = Store.append_messages(store, "s_1", [%{role: :user, content: "hi"}])

    assert [%{id: "s_1"} = touched, %{id: "s_2"}] = Store.list_sessions(store)
    assert Store.fetch_session(store, "s_1") == {:ok, touched}
  end

  test "data survives a store restart", %{store: store, path: path} do
    create(store, "s_1")
    :ok = Store.append_messages(store, "s_1", [%{role: :user, content: "hi"}])
    stop_supervised!(Store)

    store = start_supervised!({Store, path: path, name: nil})

    assert {:ok, %{id: "s_1"}} = Store.fetch_session(store, "s_1")
    assert Store.messages(store, "s_1") == [%{role: :user, content: "hi"}]
  end

  test "compactions record a summary and the first message kept", %{store: store} do
    create(store, "s_1")
    assert Store.latest_compaction(store, "s_1") == nil

    assert Store.add_compaction(store, "s_1", %{summary: "one", first_kept: 2}) == :ok
    assert Store.add_compaction(store, "s_1", %{summary: "two", first_kept: 5}) == :ok

    assert Store.latest_compaction(store, "s_1") == %{summary: "two", first_kept: 5}
    assert Store.latest_compaction(store, "missing") == nil
  end

  test "compactions leave the stored messages untouched", %{store: store, path: path} do
    create(store, "s_1")
    messages = [%{role: :user, content: "hi"}, %{role: :assistant, content: "yo", tool_calls: []}]
    :ok = Store.append_messages(store, "s_1", messages)
    :ok = Store.add_compaction(store, "s_1", %{summary: "said hi", first_kept: 2})
    stop_supervised!(Store)

    store = start_supervised!({Store, path: path, name: nil})

    assert Store.messages(store, "s_1") == messages
    assert Store.latest_compaction(store, "s_1") == %{summary: "said hi", first_kept: 2}
  end

  test "a child session records its parent", %{store: store} do
    create(store, "s_1")
    child = create_child(store, "s_2", "s_1")

    assert %{id: "s_2", parent_id: "s_1"} = child
    assert Store.fetch_session(store, "s_2") == {:ok, child}
    assert child in Store.list_sessions(store)
  end

  test "delete_session removes a session with its messages, compactions and children",
       %{store: store} do
    create(store, "s_1")
    create_child(store, "s_2", "s_1")
    create_child(store, "s_3", "s_2")
    create(store, "other")
    :ok = Store.append_messages(store, "s_1", [%{role: :user, content: "hi"}])
    :ok = Store.append_messages(store, "s_3", [%{role: :user, content: "deep"}])
    :ok = Store.add_compaction(store, "s_1", %{summary: "said hi", first_kept: 1})

    assert {:ok, deleted} = Store.delete_session(store, "s_1")
    assert deleted |> Enum.map(& &1.id) |> Enum.sort() == ["s_1", "s_2", "s_3"]

    assert Enum.map(Store.list_sessions(store), & &1.id) == ["other"]
    assert Store.messages(store, "s_3") == []
    assert Store.latest_compaction(store, "s_1") == nil
    assert Store.delete_session(store, "s_1") == {:error, :not_found}
  end

  test "a database from before child sessions gains the parent column", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "old.db")
    {:ok, conn} = Exqlite.Sqlite3.open(path)

    :ok =
      Exqlite.Sqlite3.execute(conn, """
      CREATE TABLE sessions (id TEXT PRIMARY KEY, cwd TEXT NOT NULL, model TEXT NOT NULL,
        created_at TEXT NOT NULL, updated_at TEXT NOT NULL);
      INSERT INTO sessions VALUES ('old', '/p', 'm', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z');
      """)

    :ok = Exqlite.Sqlite3.close(conn)
    store = start_supervised!({Store, path: path, name: nil}, id: :old_store)

    assert {:ok, %{id: "old", parent_id: nil}} = Store.fetch_session(store, "old")
    assert %{parent_id: "old"} = create_child(store, "new", "old")
  end
end
