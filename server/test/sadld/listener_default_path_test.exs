defmodule Sadld.ListenerDefaultPathTest do
  # Mutates XDG_RUNTIME_DIR, so it cannot run alongside other tests.
  use ExUnit.Case, async: false

  setup do
    previous = System.get_env("XDG_RUNTIME_DIR")

    on_exit(fn ->
      if previous,
        do: System.put_env("XDG_RUNTIME_DIR", previous),
        else: System.delete_env("XDG_RUNTIME_DIR")
    end)
  end

  test "places the socket under XDG_RUNTIME_DIR" do
    System.put_env("XDG_RUNTIME_DIR", "/run/user/1000")

    assert Sadld.Listener.default_path() == "/run/user/1000/sadl/sadld.sock"
  end

  test "raises when XDG_RUNTIME_DIR is unset" do
    System.delete_env("XDG_RUNTIME_DIR")

    assert_raise RuntimeError, ~r/XDG_RUNTIME_DIR/, &Sadld.Listener.default_path/0
  end
end
