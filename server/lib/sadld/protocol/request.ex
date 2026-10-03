defmodule Sadld.Protocol.Request do
  @moduledoc """
  A client → server request. `params` is an atom-keyed map shaped by the
  method's schema in `Sadld.Protocol`.
  """

  @enforce_keys [:id, :method, :params]
  defstruct [:id, :method, :params]

  @type t :: %__MODULE__{id: non_neg_integer(), method: String.t(), params: map()}
end
