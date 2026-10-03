defmodule Sadld.Protocol.Response do
  @moduledoc """
  A server → client response. Exactly one of `result` and `error` is set.

  `method` is the method of the request being answered. It is not sent on
  the wire; it selects the schema used to encode `result`, so it is required
  whenever `result` is set. `id` is `nil` only when the request's id could
  not be read.
  """

  @enforce_keys [:id]
  defstruct [:id, :method, :result, :error]

  @type error_object :: %{
          required(:code) => integer(),
          required(:message) => String.t(),
          optional(:data) => term()
        }

  @type t :: %__MODULE__{
          id: non_neg_integer() | nil,
          method: String.t() | nil,
          result: map() | nil,
          error: error_object() | nil
        }
end
