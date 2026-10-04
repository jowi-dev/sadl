defmodule Sadld.Tools.WriteTest do
  use ExUnit.Case, async: true

  alias Sadld.Tools.Write

  @moduletag :tmp_dir

  test "creates a file relative to cwd", %{tmp_dir: dir} do
    assert {:ok, message} = Write.run(%{"path" => "new.txt", "content" => "hello\n"}, dir)
    assert message =~ "6 bytes"
    assert File.read!(Path.join(dir, "new.txt")) == "hello\n"
  end

  test "overwrites an existing file", %{tmp_dir: dir} do
    path = Path.join(dir, "a.txt")
    File.write!(path, "old")

    assert {:ok, _} = Write.run(%{"path" => path, "content" => "new"}, "/")
    assert File.read!(path) == "new"
  end

  test "creates missing parent directories", %{tmp_dir: dir} do
    assert {:ok, _} = Write.run(%{"path" => "a/b/c.txt", "content" => "x"}, dir)
    assert File.read!(Path.join(dir, "a/b/c.txt")) == "x"
  end

  test "writing over a directory is an error", %{tmp_dir: dir} do
    File.mkdir_p!(Path.join(dir, "sub"))

    assert {:error, message} = Write.run(%{"path" => "sub", "content" => "x"}, dir)
    assert message =~ "directory"
  end

  test "a file in the way of a parent directory is an error", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "file"), "")

    assert {:error, message} = Write.run(%{"path" => "file/a.txt", "content" => "x"}, dir)
    assert message =~ "file"
  end

  test "invalid arguments are errors", %{tmp_dir: dir} do
    assert {:error, _} = Write.run(%{"path" => "a.txt"}, dir)
    assert {:error, _} = Write.run(%{"content" => "x"}, dir)
    assert {:error, _} = Write.run(%{"path" => "a.txt", "content" => 1}, dir)
    refute File.exists?(Path.join(dir, "a.txt"))
  end
end
