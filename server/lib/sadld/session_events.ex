defmodule Sadld.SessionEvents do
  @moduledoc """
  Publish-subscribe for session notifications, built on a `:pg` scope the
  application starts.

  Each session has the topic `"session:<id>"`. `Sadld.Session` broadcasts
  every notification on its topic, and every subscribed process receives it
  as `{:session_event, session_id, %Sadld.Protocol.Notification{}}`. Several
  processes may subscribe to one session, which is how several clients
  watch the same stream. A process leaves every topic when it exits.

  Subscribing to a session that is not running is allowed; the subscriber
  simply hears nothing until it does.
  """

  alias Sadld.Protocol.Notification

  @scope __MODULE__

  @doc false
  def child_spec(_opts), do: %{id: __MODULE__, start: {:pg, :start_link, [@scope]}}

  @doc "Subscribes the calling process to session `id`. Subscribing twice is a no-op."
  @spec subscribe(Sadld.Session.id()) :: :ok
  def subscribe(id) do
    if self() in :pg.get_local_members(@scope, topic(id)),
      do: :ok,
      else: :pg.join(@scope, topic(id), self())
  end

  @doc "Unsubscribes the calling process from session `id`."
  @spec unsubscribe(Sadld.Session.id()) :: :ok
  def unsubscribe(id) do
    :pg.leave(@scope, topic(id), self())
    :ok
  end

  @doc "Sends `notification` to every subscriber of session `id`."
  @spec broadcast(Sadld.Session.id(), Notification.t()) :: :ok
  def broadcast(id, %Notification{} = notification) do
    for pid <- :pg.get_members(@scope, topic(id)) do
      send(pid, {:session_event, id, notification})
    end

    :ok
  end

  defp topic(id), do: "session:" <> id
end
