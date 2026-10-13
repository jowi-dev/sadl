defmodule Sadld.Subagent do
  @moduledoc """
  The `task` tool, opencode's subagent: it hands a prompt to a fresh child
  session of the calling one (`Sadld.Session.create_child/1`), waits for
  the child's turn and returns its final reply as the tool's output.

  `Sadld.Session` offers it to top-level sessions only, after the built-in
  tools, so a child cannot start children of its own. The child is kept
  after the call, and deleted with its parent.
  """

  alias Sadld.{Session, Tool}

  @doc "Describes the tool to the model."
  @spec spec() :: Tool.spec()
  def spec do
    %{
      name: "task",
      description:
        "Hand a self-contained task to a subagent: a new session with your tools " <>
          "and none of this conversation, which works on `prompt` alone and answers " <>
          "with its final reply. Give it everything it needs to know in `prompt`.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "description" => %{
            "type" => "string",
            "description" => "A short (3-5 words) description of the task"
          },
          "prompt" => %{"type" => "string", "description" => "The task for the subagent"}
        },
        "required" => ["description", "prompt"]
      }
    }
  end

  @doc "Runs `prompt` from `args` in a new child of session `parent_id`."
  @spec run(map(), Session.id()) :: {:ok, String.t()} | {:error, String.t()}
  def run(args, _parent_id) when not is_map(args),
    do: {:error, "arguments to task must be a JSON object"}

  def run(args, parent_id) do
    with {:ok, prompt} <- Tool.string(args, "prompt"),
         {:ok, child} <- create_child(parent_id) do
      case Session.prompt(child, prompt) do
        {:ok, %{text: text}} -> {:ok, text}
        {:error, :cancelled} -> {:error, "the subagent was cancelled"}
        {:error, {:failed, message}} -> {:error, "the subagent failed: " <> message}
        {:error, reason} -> {:error, "the subagent failed: #{inspect(reason)}"}
      end
    end
  end

  defp create_child(parent_id) do
    case Session.create_child(parent_id) do
      {:ok, child} -> {:ok, child}
      {:error, reason} -> {:error, "could not start a subagent: #{inspect(reason)}"}
    end
  end
end
