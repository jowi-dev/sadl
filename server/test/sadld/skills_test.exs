defmodule Sadld.SkillsTest do
  use ExUnit.Case, async: true

  alias Sadld.Skills

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    project = Path.join(tmp_dir, "home/project/app")
    config_home = Path.join(tmp_dir, "config")
    File.mkdir_p!(project)
    %{project: project, config_home: config_home}
  end

  defp write_skill(dir, name, description, body \\ "Do the thing.\n") do
    path = Path.join([dir, name, "SKILL.md"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "---\nname: #{name}\ndescription: #{description}\n---\n\n#{body}")
    path
  end

  defp discover(ctx), do: Skills.discover(ctx.project, config_home: ctx.config_home)

  describe "dirs/2" do
    test "searches project dirs nearest first, then sadl's and opencode's config", ctx do
      dirs = Skills.dirs(ctx.project, config_home: ctx.config_home)

      assert Enum.take(dirs, 2) == [
               Path.join(ctx.project, ".opencode/skills"),
               Path.join(Path.dirname(ctx.project), ".opencode/skills")
             ]

      assert Enum.take(dirs, -3) == [
               "/.opencode/skills",
               Path.join(ctx.config_home, "sadl/skills"),
               Path.join(ctx.config_home, "opencode/skills")
             ]
    end
  end

  describe "parse/1" do
    test "reads name and description from the front matter and keeps the body" do
      text = "---\nname: tidy\ndescription: Tidy up: carefully.\n---\n\n# Tidy\n\nSteps.\n"

      assert Skills.parse(text) ==
               {:ok,
                %{name: "tidy", description: "Tidy up: carefully.", body: "# Tidy\n\nSteps.\n"}}
    end

    test "unquotes quoted values and ignores other keys" do
      text = ~s(---\nname: "tidy"\nlicense: MIT\ndescription: 'Tidy up'\n---\nBody)

      assert {:ok, %{name: "tidy", description: "Tidy up", body: "Body"}} = Skills.parse(text)
    end

    test "rejects text without front matter or without a name or description" do
      assert Skills.parse("# Just markdown\n") == :error
      assert Skills.parse("---\nname: tidy\n---\nBody") == :error
      assert Skills.parse("---\ndescription: Tidy\n---\nBody") == :error
      assert Skills.parse("---\nname: tidy\ndescription: Tidy\n") == :error
    end
  end

  describe "discover/2" do
    test "finds skills in every dir, sorted by name", ctx do
      write_skill(
        Path.join(ctx.config_home, "opencode/skills"),
        "thatch-fact-extractor",
        "Extract"
      )

      write_skill(Path.join(ctx.config_home, "sadl/skills"), "mine", "Mine")
      path = write_skill(Path.join(ctx.project, ".opencode/skills"), "local", "Local")

      skills = discover(ctx)

      assert Enum.map(skills, & &1.name) == ["local", "mine", "thatch-fact-extractor"]
      assert %{description: "Local", path: ^path} = hd(skills)
    end

    test "the first dir to define a name wins", ctx do
      write_skill(Path.join(ctx.config_home, "opencode/skills"), "review", "opencode")
      write_skill(Path.join(ctx.config_home, "sadl/skills"), "review", "sadl")
      write_skill(Path.join(Path.dirname(ctx.project), ".opencode/skills"), "review", "parent")

      assert [%{description: "parent"}] = discover(ctx)

      write_skill(Path.join(ctx.project, ".opencode/skills"), "review", "project")

      assert [%{description: "project"}] = discover(ctx)
    end

    test "skips dirs without a readable SKILL.md with valid front matter", ctx do
      dir = Path.join(ctx.config_home, "opencode/skills")
      File.mkdir_p!(Path.join(dir, "empty"))
      File.mkdir_p!(Path.join(dir, "bare"))
      File.write!(Path.join(dir, "bare/SKILL.md"), "no front matter")
      File.mkdir_p!(Path.join(dir, "binary"))
      File.write!(Path.join(dir, "binary/SKILL.md"), <<0xFF, 0xFE>>)
      File.write!(Path.join(dir, "stray.md"), "---\nname: stray\ndescription: x\n---\n")
      write_skill(dir, "good", "Good")

      assert [%{name: "good"}] = discover(ctx)
    end

    test "is empty when no dir exists", ctx do
      assert discover(ctx) == []
    end
  end

  describe "fetch/3" do
    test "returns the skill with its body", ctx do
      write_skill(Path.join(ctx.config_home, "opencode/skills"), "tidy", "Tidy", "Step one.\n")

      assert {:ok, %{name: "tidy", body: "Step one.\n"}} =
               Skills.fetch(ctx.project, "tidy", config_home: ctx.config_home)

      assert Skills.fetch(ctx.project, "messy", config_home: ctx.config_home) == :error
    end
  end
end
