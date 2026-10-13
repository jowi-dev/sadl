defmodule Sadld.Tools.SkillTest do
  use ExUnit.Case, async: true

  alias Sadld.Tools.Skill

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    skill_dir = Path.join(dir, ".opencode/skills/tidy")
    File.mkdir_p!(skill_dir)

    File.write!(
      Path.join(skill_dir, "SKILL.md"),
      "---\nname: tidy\ndescription: Tidy up.\n---\n\n# Tidy\n\nSweep first.\n"
    )

    %{skill_dir: skill_dir}
  end

  test "spec takes the skill name" do
    assert %{name: "skill", parameters: %{required: ["name"], properties: %{name: _}}} =
             Skill.spec()
  end

  test "returns the named skill's body and base directory", %{tmp_dir: dir, skill_dir: skill_dir} do
    assert {:ok, output} = Skill.run(%{"name" => "tidy"}, dir)
    assert output =~ "Skill: tidy"
    assert output =~ "Base directory: #{skill_dir}"
    assert output =~ "# Tidy\n\nSweep first.\n"
    refute output =~ "description:"
  end

  test "an unknown skill is an error naming the available ones", %{tmp_dir: dir} do
    assert {:error, message} = Skill.run(%{"name" => "messy"}, dir)
    assert message =~ ~s(unknown skill "messy")
    assert message =~ "tidy"
  end

  test "a missing name is an error", %{tmp_dir: dir} do
    assert {:error, message} = Skill.run(%{}, dir)
    assert message =~ "name"
  end
end
