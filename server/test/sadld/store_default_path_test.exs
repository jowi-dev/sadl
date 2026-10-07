defmodule Sadld.StoreDefaultPathTest do
  # Mutates XDG_DATA_HOME, so it cannot run alongside other tests.
  use ExUnit.Case, async: false

  setup do
    previous = System.get_env("XDG_DATA_HOME")

    on_exit(fn ->
      if previous,
        do: System.put_env("XDG_DATA_HOME", previous),
        else: System.delete_env("XDG_DATA_HOME")
    end)
  end

  test "places the database under XDG_DATA_HOME" do
    System.put_env("XDG_DATA_HOME", "/data")

    assert Sadld.Store.default_path() == "/data/sadl/sadl.db"
  end

  test "falls back to ~/.local/share when XDG_DATA_HOME is unset" do
    System.delete_env("XDG_DATA_HOME")

    assert Sadld.Store.default_path() ==
             Path.join(System.user_home!(), ".local/share/sadl/sadl.db")
  end
end
