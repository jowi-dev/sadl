defmodule Sadld.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        {Registry, keys: :unique, name: Sadld.SessionRegistry},
        {Task.Supervisor, name: Sadld.TurnSupervisor},
        {DynamicSupervisor, name: Sadld.SessionSupervisor, strategy: :one_for_one}
      ] ++ listener_children()

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Sadld.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # The listener starts last so session infrastructure is up before any
  # client can connect. Tests disable it via `config :sadld, listen: false`.
  defp listener_children do
    if Application.get_env(:sadld, :listen, true), do: [Sadld.Listener], else: []
  end
end
