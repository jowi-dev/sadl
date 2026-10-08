defmodule Sadld.Protocol do
  @moduledoc """
  Wire format for sadl protocol v0. See `docs/protocol.md`.

  Messages arrive and leave as JSON-decoded maps with string keys.
  `decode_request/1`, `decode_notification/1` and `decode_response/2` check
  a message against the schema of its method and turn its params (or result)
  into an atom-keyed map. `to_map/1` turns a message back into a string-keyed
  map ready for `JSON.encode!/1`.

  Optional fields are absent from the decoded map when absent on the wire,
  and omitted on the wire when absent or `nil` in the map. Values typed
  `:object` (such as `tool.call` `args`) and `:any` pass through untouched.
  """

  alias Sadld.Protocol.{Notification, Request, Response}

  @version 0

  @type path :: [String.t()]
  @type error ::
          :invalid_request
          | :method_not_found
          | {:invalid_params, path()}
          | {:invalid_result, path()}

  @session_info [id: :string, cwd: :string, model: :string, updated_at: :string]

  @request_params %{
    "handshake" => [protocol_version: :integer],
    "session.open" => [cwd: :string, model: {:optional, :string}],
    "session.resume" => [id: :string],
    "session.send" => [id: :string, text: :string],
    "session.cancel" => [id: :string],
    "session.permit" => [id: :string, call_id: :string, decision: {:enum, ["allow", "deny"]}],
    "session.compact" => [id: :string],
    "session.list" => []
  }

  @results %{
    "handshake" => [protocol_version: :integer],
    "session.open" => @session_info,
    "session.resume" => @session_info,
    "session.send" => [turn_id: :string],
    "session.cancel" => [],
    "session.permit" => [],
    "session.compact" => [turn_id: :string],
    "session.list" => [sessions: {:list, @session_info}]
  }

  @notification_params %{
    "turn.delta" => [session_id: :string, turn_id: :string, text: :string],
    "tool.call" => [
      session_id: :string,
      turn_id: :string,
      call_id: :string,
      name: :string,
      args: :object
    ],
    "permission.request" => [session_id: :string, turn_id: :string, call_id: :string],
    "tool.result" => [
      session_id: :string,
      turn_id: :string,
      call_id: :string,
      output: :string,
      is_error: :boolean
    ],
    "turn.end" => [
      session_id: :string,
      turn_id: :string,
      stop_reason: {:enum, ["completed", "cancelled", "error"]},
      usage: [input_tokens: :integer, output_tokens: :integer]
    ],
    "turn.compacted" => [session_id: :string, turn_id: :string, summary: :string],
    "error" => [session_id: :string, code: :integer, message: :string]
  }

  @error_object [code: :integer, message: :string, data: {:optional, :any}]

  @doc "The protocol version this server speaks."
  @spec version() :: non_neg_integer()
  def version, do: @version

  @doc """
  Decodes a client request.

  Returns `{:error, :invalid_request}` for a malformed envelope,
  `{:error, :method_not_found}` for an unknown method and
  `{:error, {:invalid_params, path}}` naming the first bad field.
  """
  @spec decode_request(map()) :: {:ok, Request.t()} | {:error, error()}
  def decode_request(%{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params})
      when is_integer(id) and id >= 0 and is_binary(method) do
    with {:ok, fields} <- fetch_schema(@request_params, method),
         {:ok, params} <- decode_params(params, fields, :invalid_params) do
      {:ok, %Request{id: id, method: method, params: params}}
    end
  end

  def decode_request(_map), do: {:error, :invalid_request}

  @doc """
  Decodes a server notification. Errors as in `decode_request/1`.
  """
  @spec decode_notification(map()) :: {:ok, Notification.t()} | {:error, error()}
  def decode_notification(%{"jsonrpc" => "2.0", "method" => method, "params" => params})
      when is_binary(method) do
    with {:ok, fields} <- fetch_schema(@notification_params, method),
         {:ok, params} <- decode_params(params, fields, :invalid_params) do
      {:ok, %Notification{method: method, params: params}}
    end
  end

  def decode_notification(_map), do: {:error, :invalid_request}

  @doc """
  Decodes a response to a request for `method`, which selects the result
  schema. A bad result field yields `{:error, {:invalid_result, path}}`.
  """
  @spec decode_response(map(), String.t()) :: {:ok, Response.t()} | {:error, error()}
  def decode_response(%{"jsonrpc" => "2.0", "id" => id, "result" => result}, method)
      when is_nil(id) or (is_integer(id) and id >= 0) do
    with {:ok, fields} <- fetch_schema(@results, method),
         {:ok, result} <- decode_params(result, fields, :invalid_result) do
      {:ok, %Response{id: id, method: method, result: result}}
    end
  end

  def decode_response(%{"jsonrpc" => "2.0", "id" => id, "error" => error}, _method)
      when is_nil(id) or (is_integer(id) and id >= 0) do
    with {:ok, error} <- decode_params(error, @error_object, :invalid_result) do
      {:ok, %Response{id: id, error: error}}
    end
  end

  def decode_response(_map, _method), do: {:error, :invalid_request}

  @doc """
  Encodes a message as a string-keyed map ready for `JSON.encode!/1`.

  A `Response` with a non-nil `error` encodes as an error response,
  otherwise as a result.
  """
  @spec to_map(Request.t() | Response.t() | Notification.t()) :: map()
  def to_map(%Request{id: id, method: method, params: params}) do
    fields = Map.fetch!(@request_params, method)

    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => method,
      "params" => encode_object(params, fields)
    }
  end

  def to_map(%Notification{method: method, params: params}) do
    fields = Map.fetch!(@notification_params, method)
    %{"jsonrpc" => "2.0", "method" => method, "params" => encode_object(params, fields)}
  end

  def to_map(%Response{id: id, error: error}) when error != nil do
    %{"jsonrpc" => "2.0", "id" => id, "error" => encode_object(error, @error_object)}
  end

  def to_map(%Response{id: id, method: method, result: result}) do
    fields = Map.fetch!(@results, method)
    %{"jsonrpc" => "2.0", "id" => id, "result" => encode_object(result, fields)}
  end

  defp fetch_schema(schemas, method) do
    case Map.fetch(schemas, method) do
      {:ok, fields} -> {:ok, fields}
      :error -> {:error, :method_not_found}
    end
  end

  defp decode_params(value, fields, tag) do
    case decode_value(value, fields, []) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, path} -> {:error, {tag, Enum.reverse(path)}}
    end
  end

  # Returns {:ok, decoded} or {:error, reversed_path}.
  defp decode_value(value, fields, path) when is_list(fields) do
    if is_map(value), do: decode_object(value, fields, path), else: {:error, path}
  end

  defp decode_value(value, {:list, type}, path) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {item, index}, {:ok, acc} ->
      case decode_value(item, type, [Integer.to_string(index) | path]) do
        {:ok, decoded} -> {:cont, {:ok, [decoded | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      error -> error
    end
  end

  defp decode_value(value, {:enum, values}, path) do
    if value in values, do: {:ok, value}, else: {:error, path}
  end

  defp decode_value(value, :string, _path) when is_binary(value), do: {:ok, value}
  defp decode_value(value, :integer, _path) when is_integer(value), do: {:ok, value}
  defp decode_value(value, :boolean, _path) when is_boolean(value), do: {:ok, value}
  defp decode_value(value, :object, _path) when is_map(value), do: {:ok, value}
  defp decode_value(value, :any, _path), do: {:ok, value}
  defp decode_value(_value, _type, path), do: {:error, path}

  defp decode_object(map, fields, path) do
    Enum.reduce_while(fields, {:ok, %{}}, fn {key, type}, {:ok, acc} ->
      name = Atom.to_string(key)

      case decode_field(map, name, type, [name | path]) do
        {:ok, :absent} -> {:cont, {:ok, acc}}
        {:ok, decoded} -> {:cont, {:ok, Map.put(acc, key, decoded)}}
        error -> {:halt, error}
      end
    end)
  end

  defp decode_field(map, name, {:optional, type}, path) do
    case Map.fetch(map, name) do
      {:ok, nil} -> {:ok, :absent}
      {:ok, value} -> decode_value(value, type, path)
      :error -> {:ok, :absent}
    end
  end

  defp decode_field(map, name, type, path) do
    case Map.fetch(map, name) do
      {:ok, value} -> decode_value(value, type, path)
      :error -> {:error, path}
    end
  end

  defp encode_object(map, fields) do
    Enum.reduce(fields, %{}, fn {key, type}, acc ->
      case Map.get(map, key) do
        nil -> acc
        value -> Map.put(acc, Atom.to_string(key), encode_value(value, type))
      end
    end)
  end

  defp encode_value(value, fields) when is_list(fields), do: encode_object(value, fields)
  defp encode_value(value, {:list, type}), do: Enum.map(value, &encode_value(&1, type))
  defp encode_value(value, {:optional, type}), do: encode_value(value, type)
  defp encode_value(value, _type), do: value
end
