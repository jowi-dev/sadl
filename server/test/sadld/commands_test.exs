defmodule Sadld.CommandsTest do
  use ExUnit.Case, async: true

  alias Sadld.Commands

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    opencode = Path.join(tmp_dir, "opencode")
    sadl = Path.join(tmp_dir, "sadl")
    %{dirs: [opencode, sadl], opencode: opencode, sadl: sadl}
  end

  defp write(dir, path, contents) do
    path = Path.join(dir, path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
  end

  test "finds a command by its path under command/ or commands/, front matter dropped", ctx do
    write(ctx.opencode, "command/thatch/compact.md", """
    ---
    description: Wrap up and compact
    ---

    Summarise the session.
    """)

    write(ctx.opencode, "commands/review.md", "Review the diff.\n")

    assert Commands.fetch("thatch/compact", ctx.dirs) == {:ok, "Summarise the session."}
    assert Commands.fetch("review", ctx.dirs) == {:ok, "Review the diff."}
    assert Commands.fetch("missing", ctx.dirs) == :error
    assert Commands.fetch("../escape", ctx.dirs) == :error
  end

  test "a later directory's command replaces an earlier one's", ctx do
    write(ctx.opencode, "command/review.md", "opencode")
    write(ctx.sadl, "command/review.md", "sadl")

    assert Commands.fetch("review", ctx.dirs) == {:ok, "sadl"}
  end

  test "the default directories are opencode's and sadl's under the config home" do
    config_home = Path.dirname(Sadld.config_dir())

    assert Commands.default_dirs() == [
             Path.join(config_home, "opencode"),
             Sadld.config_dir()
           ]
  end

  describe "expand/2" do
    test "replaces $ARGUMENTS with the whole argument string" do
      assert Commands.expand("Fix $ARGUMENTS now. ($ARGUMENTS)", "issue 12") ==
               "Fix issue 12 now. (issue 12)"
    end

    test "replaces $1, $2, ... with words, the last taking the rest" do
      assert Commands.expand("from $1 to $2", "a b c") == "from a to b c"
      assert Commands.expand("only $2", "a") == "only "
    end

    test "appends arguments to a template that takes none" do
      assert Commands.expand("Review.", "the parser") == "Review.\n\nthe parser"
      assert Commands.expand("Review.", "  ") == "Review."
    end
  end
end
