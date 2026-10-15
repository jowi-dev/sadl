defmodule Sadld.Sidecar.Client do
  @moduledoc """
  Answers the opencode SDK calls a plugin's `client` makes, the
  host → sadld requests of `docs/sidecar.md`, in opencode's response shapes.

  Each answer is computed in the caller, which `Sadld.Sidecar` runs in a
  task of its own: answering may call a session that is itself waiting on
  the sidecar.
  """

  require Logger

  alias Sadld.{Plugin, Session, SessionEvents, Store}
  alias Sadld.Protocol.Notification

  @method_not_found -32_601
  @invalid_params -32_602
  @session_not_found -32_002
  @session_busy -32_003

  @variants ["info", "success", "warning", "error"]

  @doc """
  Answers SDK call `method` with `params`, for a plugin serving `worktree`.

  opencode's TUI calls name no session, since they act on the one its TUI
  shows. Here they act on `session`, the one the plugin last heard about,
  and fail with session not found when there is none.
  """
  @spec handle(String.t(), map(), Path.t(), Session.id() | nil) ::
          {:ok, term()} | {:error, integer(), String.t()}
  def handle(method, params, worktree, session \\ nil)

  def handle("tui.executeCommand", %{"body" => %{"command" => command}}, _worktree, session)
      when is_binary(command),
      do: tui_command(command, session)

  def handle(
        "tui.publish",
        %{"body" => %{"type" => "tui.command.execute", "properties" => %{"command" => command}}},
        _worktree,
        session
      )
      when is_binary(command),
      do: tui_command(command, session)

  def handle("session.get", %{"path" => %{"id" => id}}, _worktree, _session) when is_binary(id) do
    case Store.fetch_session(id) do
      {:ok, info} -> {:ok, Plugin.session(info)}
      {:error, :not_found} -> not_found()
    end
  end

  def handle("session.list", _params, worktree, _session) do
    sessions = for info <- Store.list_sessions(), within?(info.cwd, worktree), do: info
    {:ok, Enum.map(sessions, &Plugin.session/1)}
  end

  def handle("session.status", _params, worktree, _session) do
    statuses =
      for id <- running_in(worktree),
          status when is_atom(status) <- [Session.status(id)],
          into: %{},
          do: {id, %{"type" => Atom.to_string(status)}}

    {:ok, statuses}
  end

  def handle("session.messages", %{"path" => %{"id" => id}}, _worktree, _session)
      when is_binary(id) do
    with messages when is_list(messages) <- messages(id) do
      {:ok,
       for {message, index} <- Enum.with_index(messages),
           message.role != :tool,
           message.content != "" do
         %{
           "info" => %{
             "id" => "#{id}_#{index}",
             "sessionID" => id,
             "role" => Atom.to_string(message.role)
           },
           "parts" => [part(message.content, message[:synthetic])]
         }
       end}
    end
  end

  def handle(
        method,
        %{"path" => %{"id" => id}, "body" => %{"parts" => parts} = body},
        _worktree,
        _session
      )
      when method in ["session.prompt", "session.promptAsync"] and is_binary(id) and
             is_list(parts) do
    texts = for %{"type" => "text", "text" => text} <- parts, is_binary(text), do: text
    text = Enum.join(texts, "\n\n")
    synthetic = Enum.any?(parts, &(&1["synthetic"] == true))
    opts = [synthetic: synthetic, no_reply: body["noReply"] == true]

    case Session.send_message(id, text, opts) do
      {:ok, _turn_id} when method == "session.promptAsync" ->
        {:ok, %{}}

      {:ok, _turn_id} ->
        {:ok,
         %{"info" => %{"sessionID" => id, "role" => "user"}, "parts" => [part(text, synthetic)]}}

      {:error, :busy} ->
        {:error, @session_busy, "session busy"}

      {:error, :not_found} ->
        not_found()
    end
  end

  def handle("tui.showToast", %{"body" => %{"message" => message} = body}, worktree, _session)
      when is_binary(message) do
    Logger.info("plugin notice in #{worktree}: #{message}")

    variant = if body["variant"] in @variants, do: body["variant"], else: "info"
    params = %{message: message, variant: variant}

    params =
      if is_integer(body["duration"]),
        do: Map.put(params, :duration_ms, body["duration"]),
        else: params

    for id <- running_in(worktree) do
      SessionEvents.broadcast(id, %Notification{
        method: "notice",
        params: Map.put(params, :session_id, id)
      })
    end

    {:ok, true}
  end

  def handle(method, _params, _worktree, _session)
      when method in [
             "session.get",
             "session.messages",
             "session.prompt",
             "session.promptAsync",
             "tui.showToast",
             "tui.executeCommand",
             "tui.publish"
           ],
      do: {:error, @invalid_params, "invalid params"}

  def handle(_method, _params, _worktree, _session),
    do: {:error, @method_not_found, "method not found"}

  # opencode's TUI takes both the current command names and the older
  # snake_case ones.
  defp tui_command(_command, nil), do: not_found()

  defp tui_command(command, session) when command in ["session_compact", "session.compact"] do
    case Session.compact(session) do
      {:ok, _turn_id} -> {:ok, true}
      {:error, :busy} -> {:error, @session_busy, "session busy"}
      {:error, :not_found} -> not_found()
    end
  end

  defp tui_command(command, session) when command in ["app_exit", "app.exit"] do
    case Session.request_exit(session) do
      :ok -> {:ok, true}
      {:error, :not_found} -> not_found()
    end
  end

  defp tui_command(command, _session),
    do: {:error, @invalid_params, "unsupported TUI command " <> command}

  defp messages(id) do
    case Session.messages(id) do
      {:error, :not_found} ->
        case Store.fetch_session(id) do
          {:ok, _info} -> Store.messages(id)
          {:error, :not_found} -> not_found()
        end

      messages ->
        messages
    end
  end

  defp part(text, true), do: %{"type" => "text", "text" => text, "synthetic" => true}
  defp part(text, _synthetic), do: %{"type" => "text", "text" => text}

  defp not_found, do: {:error, @session_not_found, "session not found"}

  # The ids of the running sessions working in `worktree` or below it.
  defp running_in(worktree) do
    for id <- Session.running(),
        %{cwd: cwd} <- [Session.info(id)],
        within?(cwd, worktree),
        do: id
  end

  defp within?(cwd, worktree), do: cwd == worktree or String.starts_with?(cwd, worktree <> "/")
end
