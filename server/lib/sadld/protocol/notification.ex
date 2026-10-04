defmodule Sadld.Protocol.Notification do
  @moduledoc """
  A server → client notification. `params` is an atom-keyed map shaped by
  the method's schema in `Sadld.Protocol`.
  """

  @enforce_keys [:method, :params]
  defstruct [:method, :params]

  @type t :: %__MODULE__{method: String.t(), params: map()}
end
