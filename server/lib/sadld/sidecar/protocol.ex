defmodule Sadld.Sidecar.Protocol do
  @moduledoc """
  Encodes and decodes the lines of the plugin sidecar protocol
  (`docs/sidecar.md`).

  Messages are tuples, and their params and results stay as decoded JSON
  with string keys, since the sidecar passes opencode's shapes through:

    * `{:request, id, method, params}`
    * `{:notification, method, params}`
    * `{:response, id, {:ok, result}}` or
      `{:response, id, {:error, code, message}}`
  """

  @type message ::
          {:request, non_neg_integer(), String.t(), map()}
          | {:notification, String.t(), map()}
          | {:response, non_neg_integer(), {:ok, term()} | {:error, integer(), String.t()}}

  @doc "Decodes one line. Fails with `:invalid` on anything but a message."
  @spec decode(String.t()) :: {:ok, message()} | {:error, :invalid}
  def decode(line) do
    case JSON.decode(line) do
      {:ok, map} when is_map(map) -> from_map(map)
      _other -> {:error, :invalid}
    end
  end

  defp from_map(%{"id" => id, "method" => method, "params" => params})
       when is_integer(id) and is_binary(method) and is_map(params),
       do: {:ok, {:request, id, method, params}}

  defp from_map(%{"method" => method, "params" => params} = map)
       when is_binary(method) and is_map(params) and not is_map_key(map, "id"),
       do: {:ok, {:notification, method, params}}

  defp from_map(%{"id" => id, "result" => result}) when is_integer(id),
    do: {:ok, {:response, id, {:ok, result}}}

  defp from_map(%{"id" => id, "error" => %{"code" => code, "message" => message}})
       when is_integer(id) and is_integer(code) and is_binary(message),
       do: {:ok, {:response, id, {:error, code, message}}}

  defp from_map(_map), do: {:error, :invalid}

  @doc "Encodes `message` as one line of JSON, without the trailing newline."
  @spec encode(message()) :: String.t()
  def encode(message), do: message |> to_map() |> JSON.encode!()

  defp to_map({:request, id, method, params}),
    do: %{jsonrpc: "2.0", id: id, method: method, params: params}

  defp to_map({:notification, method, params}),
    do: %{jsonrpc: "2.0", method: method, params: params}

  defp to_map({:response, id, {:ok, result}}), do: %{jsonrpc: "2.0", id: id, result: result}

  defp to_map({:response, id, {:error, code, message}}),
    do: %{jsonrpc: "2.0", id: id, error: %{code: code, message: message}}
end
