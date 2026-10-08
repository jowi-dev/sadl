defmodule Sadld.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        {Sadld.Store, path: store_path()},
        {Registry, keys: :unique, name: Sadld.SessionRegistry},
        Sadld.SessionEvents,
        {Task.Supervisor, name: Sadld.TurnSupervisor},
        {Task.Supervisor, name: Sadld.PluginTaskSupervisor},
        {DynamicSupervisor, name: Sadld.SessionSupervisor, strategy: :one_for_one}
      ] ++ listener_children()

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Sadld.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp store_path, do: Application.get_env(:sadld, :store_path) || Sadld.Store.default_path()

  # The listener starts last so session infrastructure is up before any
  # client can connect. Tests disable it via `config :sadld, listen: false`.
  defp listener_children do
    if Application.get_env(:sadld, :listen, true), do: [Sadld.Listener], else: []
  end
end
