defmodule Sadld do
  @moduledoc """
  Documentation for `Sadld`.
  """

  @doc """
  Hello world.

  ## Examples

      iex> Sadld.hello()
      :world

  """
  def hello do
    :world
  end

  @doc "The user's sadl config directory: `$XDG_CONFIG_HOME/sadl`, or `~/.config/sadl`."
  @spec config_dir() :: Path.t()
  def config_dir do
    config_home =
      case System.get_env("XDG_CONFIG_HOME") do
        home when home in [nil, ""] -> Path.join(System.user_home!(), ".config")
        home -> home
      end

    Path.join(config_home, "sadl")
  end
end
