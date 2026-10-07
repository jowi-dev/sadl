defmodule Sadld.Tools.EditTest do
  use ExUnit.Case, async: true

  alias Sadld.Tools.Edit

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    path = Path.join(dir, "a.ex")
    File.write!(path, "def a, do: 1\ndef b, do: 2\n")
    %{path: path}
  end

  defp edit(dir, old, new), do: Edit.run(%{"path" => "a.ex", "old" => old, "new" => new}, dir)

  test "replaces the one exact match", %{tmp_dir: dir, path: path} do
    assert {:ok, message} = edit(dir, "do: 2", "do: 3")
    assert message =~ path
    assert File.read!(path) == "def a, do: 1\ndef b, do: 3\n"
  end

  test "can replace text spanning lines", %{tmp_dir: dir, path: path} do
    assert {:ok, _} = edit(dir, "1\ndef b", "1\n\ndef b")
    assert File.read!(path) == "def a, do: 1\n\ndef b, do: 2\n"
  end

  test "can delete text", %{tmp_dir: dir, path: path} do
    assert {:ok, _} = edit(dir, "def b, do: 2\n", "")
    assert File.read!(path) == "def a, do: 1\n"
  end

  test "fails when old is missing and leaves the file alone", %{tmp_dir: dir, path: path} do
    assert {:error, message} = edit(dir, "do: 9", "do: 3")
    assert message =~ "not found"
    assert File.read!(path) == "def a, do: 1\ndef b, do: 2\n"
  end

  test "fails when old matches more than once", %{tmp_dir: dir, path: path} do
    assert {:error, message} = edit(dir, "def ", "defp ")
    assert message =~ "2 times"
    assert File.read!(path) == "def a, do: 1\ndef b, do: 2\n"
  end

  test "counts overlapping matches as ambiguous", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "a.ex"), "aaa")

    assert {:error, message} = edit(dir, "aa", "b")
    assert message =~ "2 times"
  end

  test "fails when old is empty", %{tmp_dir: dir} do
    assert {:error, message} = edit(dir, "", "x")
    assert message =~ "empty"
  end

  test "fails on a missing file", %{tmp_dir: dir} do
    assert {:error, message} =
             Edit.run(%{"path" => "nope.ex", "old" => "a", "new" => "b"}, dir)

    assert message =~ "nope.ex"
  end

  test "invalid arguments are errors", %{tmp_dir: dir} do
    assert {:error, _} = Edit.run(%{"path" => "a.ex", "old" => "a"}, dir)
    assert {:error, _} = Edit.run(%{"path" => "a.ex", "new" => "a"}, dir)
    assert {:error, _} = Edit.run(%{"path" => "a.ex", "old" => 1, "new" => "a"}, dir)
  end
end
