defmodule Sadld.Tools.ReadTest do
  use ExUnit.Case, async: true

  alias Sadld.Tools.Read

  @moduletag :tmp_dir

  defp write_lines(dir, name, lines) do
    path = Path.join(dir, name)
    File.write!(path, Enum.join(lines, "\n") <> "\n")
    path
  end

  test "returns the file with line numbers", %{tmp_dir: dir} do
    write_lines(dir, "a.txt", ["alpha", "beta"])

    assert Read.run(%{"path" => "a.txt"}, dir) == {:ok, "     1\talpha\n     2\tbeta\n"}
  end

  test "accepts an absolute path", %{tmp_dir: dir} do
    path = write_lines(dir, "a.txt", ["alpha"])

    assert Read.run(%{"path" => path}, "/") == {:ok, "     1\talpha\n"}
  end

  test "offset and limit select a window of lines", %{tmp_dir: dir} do
    write_lines(dir, "a.txt", ["one", "two", "three", "four"])

    assert {:ok, output} = Read.run(%{"path" => "a.txt", "offset" => 2, "limit" => 2}, dir)
    assert output =~ "     2\ttwo\n     3\tthree\n"
    refute output =~ "one"
    assert output =~ "lines 2-3 of 4"
    assert output =~ "offset=4"
  end

  test "an offset past the end is an error", %{tmp_dir: dir} do
    write_lines(dir, "a.txt", ["one"])

    assert {:error, message} = Read.run(%{"path" => "a.txt", "offset" => 5}, dir)
    assert message =~ "offset 5"
    assert message =~ "1 line"
  end

  test "an empty file reads as empty", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "empty.txt"), "")

    assert Read.run(%{"path" => "empty.txt"}, dir) == {:ok, ""}
  end

  test "a long file is cut at the default line limit", %{tmp_dir: dir} do
    write_lines(dir, "big.txt", Enum.map(1..2_500, &"line #{&1}"))

    assert {:ok, output} = Read.run(%{"path" => "big.txt"}, dir)
    assert output =~ "  2000\tline 2000\n"
    refute output =~ "line 2001"
    assert output =~ "lines 1-2000 of 2500"
  end

  test "output is capped in bytes", %{tmp_dir: dir} do
    write_lines(dir, "wide.txt", List.duplicate(String.duplicate("x", 1_000), 200))

    assert {:ok, output} = Read.run(%{"path" => "wide.txt"}, dir)
    assert byte_size(output) < 60_000
    assert output =~ "of 200"
  end

  test "very long lines are shortened", %{tmp_dir: dir} do
    write_lines(dir, "line.txt", [String.duplicate("y", 5_000)])

    assert {:ok, output} = Read.run(%{"path" => "line.txt"}, dir)
    assert byte_size(output) < 2_200
    assert output =~ "line truncated"
  end

  test "a missing file is an error", %{tmp_dir: dir} do
    assert {:error, message} = Read.run(%{"path" => "nope.txt"}, dir)
    assert message =~ "nope.txt"
  end

  test "a directory is an error", %{tmp_dir: dir} do
    assert {:error, message} = Read.run(%{"path" => "."}, dir)
    assert message =~ "directory"
  end

  test "a binary file is an error", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "bin"), <<0xFF, 0xFE, 0x00>>)

    assert {:error, message} = Read.run(%{"path" => "bin"}, dir)
    assert message =~ "UTF-8"
  end

  test "invalid arguments are errors", %{tmp_dir: dir} do
    assert {:error, _} = Read.run(%{}, dir)
    assert {:error, _} = Read.run(%{"path" => 1}, dir)
    assert {:error, _} = Read.run(%{"path" => "a", "offset" => 0}, dir)
    assert {:error, _} = Read.run(%{"path" => "a", "limit" => "10"}, dir)
  end
end
