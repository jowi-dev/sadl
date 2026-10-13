defmodule Sadld.Tools.Skill do
  @moduledoc """
  The `skill` tool: loads a skill found by `Sadld.Skills` and returns its
  instructions, the body of its `SKILL.md`, headed by the skill's name and
  the directory it lives in so the model can resolve files it mentions.

  Skills are looked up when the tool runs, so ones installed after the
  session started can still be loaded. The system prompt lists the skills
  available when the session started.
  """

  @behaviour Sadld.Tool

  alias Sadld.{Skills, Tool}

  @impl true
  def spec do
    %{
      name: "skill",
      description:
        "Load a skill: detailed instructions for a specific kind of task. " <>
          "Pass the name of one of the skills listed in the system prompt, " <>
          "then follow the instructions it returns.",
      parameters: %{
        type: "object",
        properties: %{
          name: %{type: "string", description: "Name of the skill to load"}
        },
        required: ["name"]
      }
    }
  end

  @impl true
  def run(args, cwd) do
    with {:ok, name} <- Tool.string(args, "name") do
      case Skills.fetch(cwd, name) do
        {:ok, skill} -> {:ok, render(skill)}
        :error -> {:error, "unknown skill #{inspect(name)}; #{available(cwd)}"}
      end
    end
  end

  defp render(skill) do
    "Skill: #{skill.name}\nBase directory: #{Path.dirname(skill.path)}\n\n#{skill.body}"
  end

  defp available(cwd) do
    case Skills.discover(cwd) do
      [] -> "no skills are installed"
      skills -> "available skills: " <> Enum.map_join(skills, ", ", & &1.name)
    end
  end
end
