defmodule Sadld.SystemPromptTest do
  use ExUnit.Case, async: true

  alias Sadld.SystemPrompt

  @moduletag :tmp_dir

  @tools [
    %{name: "read", description: "Read a text file.", parameters: %{}},
    %{name: "edit", description: "Replace text in a file.", parameters: %{}}
  ]

  setup %{tmp_dir: tmp_dir} do
    project = Path.join(tmp_dir, "home/project/app")
    config_dir = Path.join(tmp_dir, "config/sadl")
    File.mkdir_p!(project)
    File.mkdir_p!(config_dir)
    %{project: project, config_dir: config_dir}
  end

  defp build(cwd, config_dir, opts \\ []) do
    opts = Keyword.merge([tools: @tools, os: "linux", date: ~D[2026-10-06]], opts)
    SystemPrompt.build(cwd, Keyword.put(opts, :config_dir, config_dir))
  end

  test "describes the tools, working directory, OS and date", ctx do
    prompt = build(ctx.project, ctx.config_dir)

    assert prompt =~ "- read: Read a text file."
    assert prompt =~ "- edit: Replace text in a file."
    assert prompt =~ "Working directory: #{ctx.project}"
    assert prompt =~ "Operating system: linux"
    assert prompt =~ "Today's date: 2026-10-06"
  end

  test "appends AGENTS.md from the cwd and its ancestors, outermost first", ctx do
    home = Path.expand("../..", ctx.project)
    File.write!(Path.join(home, "AGENTS.md"), "home rules")
    File.write!(Path.join(ctx.project, "AGENTS.md"), "app rules")

    prompt = build(ctx.project, ctx.config_dir)

    assert prompt =~ "## #{Path.join(home, "AGENTS.md")}\n\nhome rules"
    assert prompt =~ "## #{Path.join(ctx.project, "AGENTS.md")}\n\napp rules"
    assert :binary.match(prompt, "home rules") < :binary.match(prompt, "app rules")
  end

  test "falls back to CLAUDE.md only where a directory has no AGENTS.md", ctx do
    parent = Path.dirname(ctx.project)
    File.write!(Path.join(parent, "CLAUDE.md"), "parent claude")
    File.write!(Path.join(ctx.project, "AGENTS.md"), "app agents")
    File.write!(Path.join(ctx.project, "CLAUDE.md"), "app claude")

    prompt = build(ctx.project, ctx.config_dir)

    assert prompt =~ "parent claude"
    assert prompt =~ "app agents"
    refute prompt =~ "app claude"
  end

  test "puts the user-global file before the project ones", ctx do
    File.write!(Path.join(ctx.config_dir, "AGENTS.md"), "global rules")
    File.write!(Path.join(ctx.project, "AGENTS.md"), "app rules")

    prompt = build(ctx.project, ctx.config_dir)

    assert prompt =~ "## #{Path.join(ctx.config_dir, "AGENTS.md")}\n\nglobal rules"
    assert :binary.match(prompt, "global rules") < :binary.match(prompt, "app rules")
  end

  test "the user-global file also falls back to CLAUDE.md", ctx do
    File.write!(Path.join(ctx.config_dir, "CLAUDE.md"), "global claude")

    assert build(ctx.project, ctx.config_dir) =~ "global claude"
  end

  test "does not read the global file twice when the cwd is the config dir", ctx do
    File.write!(Path.join(ctx.config_dir, "AGENTS.md"), "global rules")

    prompt = build(ctx.config_dir, ctx.config_dir)

    assert length(:binary.matches(prompt, "global rules")) == 1
  end

  test "skips context files that are not readable text", ctx do
    File.mkdir_p!(Path.join(ctx.project, "AGENTS.md"))
    File.write!(Path.join(ctx.project, "CLAUDE.md"), <<0xFF, 0xFE>>)

    prompt = build(ctx.project, ctx.config_dir)

    refute prompt =~ "## #{ctx.project}"
  end

  test "defaults to the built-in tools, the host OS and today", ctx do
    prompt = SystemPrompt.build(ctx.project, config_dir: ctx.config_dir)

    for tool <- Sadld.Tools.specs(), do: assert(prompt =~ "- #{tool.name}: ")
    assert prompt =~ "Today's date: #{Date.utc_today()}"
    refute prompt =~ "Operating system: \n"
  end

  describe "skills" do
    @skill_tool %{name: "skill", description: "Load a skill.", parameters: %{}}
    @skills [
      %{name: "tidy", description: "Tidy up.", body: "", path: "/s/tidy/SKILL.md"},
      %{name: "review", description: "Review code.", body: "", path: "/s/review/SKILL.md"}
    ]

    test "lists the available skills when the skill tool is offered", ctx do
      prompt = build(ctx.project, ctx.config_dir, tools: [@skill_tool | @tools], skills: @skills)

      assert prompt =~ "Skills"
      assert prompt =~ "- tidy: Tidy up.\n- review: Review code."
    end

    test "leaves skills out without the skill tool or without skills", ctx do
      refute build(ctx.project, ctx.config_dir, skills: @skills) =~ "- tidy:"
      refute build(ctx.project, ctx.config_dir, tools: [@skill_tool], skills: []) =~ "Skills"
    end

    test "discovers the skills visible from the cwd by default", ctx do
      dir = Path.join(ctx.project, ".opencode/skills/tidy")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "SKILL.md"), "---\nname: tidy\ndescription: Tidy up.\n---\n")

      assert build(ctx.project, ctx.config_dir, tools: [@skill_tool]) =~ "- tidy: Tidy up."
    end
  end
end
