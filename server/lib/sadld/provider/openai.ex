defmodule Sadld.Provider.OpenAI do
  @moduledoc """
  A `Sadld.Provider` for OpenAI-compatible chat completion APIs, pointed at
  Venice.ai by default. It also fits OpenRouter, Ollama and the like.

  Each `chat/2` posts a streaming request to `<base_url>/chat/completions`
  and reads the server-sent events as they arrive: text deltas go to the
  `:on_text` callback, tool calls are assembled from their fragments, and
  the usage the server reports at the end becomes the reply's usage.

  ## Options

  Options come from the session's `:provider` opts, layered over
  `config :sadld, Sadld.Provider.OpenAI, ...`:

    * `:base_url` - API root (default `"https://api.venice.ai/api/v1"`)
    * `:model` - model name (default `default_model/0`); the session
      passes its own
    * `:system` - system prompt, sent as the first message; the session
      passes its own
    * `:api_key` - API key; normally left unset in favour of the
      `VENICE_API_KEY` environment variable or `:api_key_file`
    * `:api_key_file` - file holding the API key, read when
      `VENICE_API_KEY` is unset (default `default_api_key_file/0`)
    * `:tools` - tool definitions offered to the model, as maps with
      `:name`, `:description` and `:parameters` (a JSON Schema object)
    * `:req_options` - extra `Req` options, such as a `Req.Test` plug

  The API key is sent only in the `authorization` header. Keep it out of
  committed config; error reasons never include it.

  ## Errors

    * `:missing_api_key` - no key in the options, environment or key file
    * `{:http_status, status, body}` - the server answered with a non-2xx
      status
    * `{:api_error, message}` - the stream carried an error event
    * `{:transport_error, reason}` - the connection failed
    * `{:invalid_event, data}` - a stream event was not valid JSON
    * `{:invalid_tool_arguments, name, arguments}` - a tool call's
      arguments were not a JSON object
  """

  @behaviour Sadld.Provider

  alias Sadld.Provider.SSE

  @default_base_url "https://api.venice.ai/api/v1"
  @default_model "z-ai-glm-5-3-flash"
  @api_key_env "VENICE_API_KEY"

  @doc "The model used when neither the session nor the config names one."
  @spec default_model() :: String.t()
  def default_model, do: @default_model

  @doc "The key file read by default: `$XDG_CONFIG_HOME/sadl/api_key`."
  @spec default_api_key_file() :: Path.t()
  def default_api_key_file, do: Path.join(Sadld.config_dir(), "api_key")

  @impl true
  def chat(messages, opts) do
    opts = Keyword.merge(Application.get_env(:sadld, __MODULE__, []), opts)

    with {:ok, api_key} <- api_key(opts) do
      initial = %{
        sse: SSE.new(),
        on_text: Keyword.fetch!(opts, :on_text),
        text: [],
        calls: %{},
        usage: nil,
        error: nil,
        error_body: []
      }

      [
        method: :post,
        base_url: Keyword.get(opts, :base_url, @default_base_url),
        url: "/chat/completions",
        auth: {:bearer, api_key},
        json: request_body(messages, opts),
        into: fn {:data, data}, {req, resp} ->
          stream = Req.Response.get_private(resp, :stream, initial)
          stream = receive_data(stream, resp.status, data)
          resp = Req.Response.put_private(resp, :stream, stream)
          {if(stream.error, do: :halt, else: :cont), {req, resp}}
        end
      ]
      |> Keyword.merge(Keyword.get(opts, :req_options, []))
      |> Req.request()
      |> finish(initial)
    end
  end

  defp api_key(opts) do
    key =
      Keyword.get(opts, :api_key) || System.get_env(@api_key_env) ||
        read_key_file(Keyword.get(opts, :api_key_file, default_api_key_file()))

    case key && String.trim(key) do
      present when present not in [nil, ""] -> {:ok, present}
      _missing -> {:error, :missing_api_key}
    end
  end

  defp read_key_file(path) do
    case File.read(path) do
      {:ok, contents} -> contents
      {:error, _reason} -> nil
    end
  end

  ## Request

  defp request_body(messages, opts) do
    body = %{
      model: Keyword.get(opts, :model, @default_model),
      messages: system_message(opts) ++ Enum.map(messages, &encode_message/1),
      stream: true,
      stream_options: %{include_usage: true}
    }

    case Keyword.get(opts, :tools, []) do
      [] -> body
      tools -> Map.put(body, :tools, Enum.map(tools, &encode_tool/1))
    end
  end

  defp system_message(opts) do
    case Keyword.get(opts, :system) do
      nil -> []
      system -> [%{role: "system", content: system}]
    end
  end

  defp encode_message(%{role: :user, content: content}), do: %{role: "user", content: content}

  defp encode_message(%{role: :assistant, content: content, tool_calls: []}),
    do: %{role: "assistant", content: content}

  defp encode_message(%{role: :assistant, content: content, tool_calls: calls}) do
    %{
      role: "assistant",
      content: if(content == "", do: nil, else: content),
      tool_calls: Enum.map(calls, &encode_tool_call/1)
    }
  end

  defp encode_message(%{role: :tool, call_id: call_id, content: content}),
    do: %{role: "tool", tool_call_id: call_id, content: content}

  defp encode_tool_call(%{id: id, name: name, args: args}),
    do: %{id: id, type: "function", function: %{name: name, arguments: Jason.encode!(args)}}

  defp encode_tool(tool),
    do: %{type: "function", function: Map.take(tool, [:name, :description, :parameters])}

  ## Response stream

  defp receive_data(stream, status, data) when status in 200..299 do
    {events, sse} = SSE.parse(stream.sse, data)
    Enum.reduce_while(events, %{stream | sse: sse}, &receive_event/2)
  end

  defp receive_data(stream, _status, data), do: %{stream | error_body: [stream.error_body, data]}

  defp receive_event("[DONE]", stream), do: {:cont, stream}

  defp receive_event(data, stream) do
    case Jason.decode(data) do
      {:ok, %{"error" => error}} -> {:halt, %{stream | error: {:api_error, error_message(error)}}}
      {:ok, chunk} when is_map(chunk) -> {:cont, receive_chunk(chunk, stream)}
      _invalid -> {:halt, %{stream | error: {:invalid_event, data}}}
    end
  end

  defp error_message(%{"message" => message}) when is_binary(message), do: message
  defp error_message(error) when is_binary(error), do: error
  defp error_message(error), do: Jason.encode!(error)

  defp receive_chunk(chunk, stream) do
    stream =
      case chunk do
        %{"usage" => %{} = usage} -> %{stream | usage: usage}
        _no_usage -> stream
      end

    case chunk do
      %{"choices" => [%{"delta" => %{} = delta} | _rest]} -> receive_delta(delta, stream)
      _no_delta -> stream
    end
  end

  defp receive_delta(delta, stream) do
    stream =
      case delta do
        %{"content" => text} when is_binary(text) and text != "" ->
          stream.on_text.(text)
          %{stream | text: [stream.text, text]}

        _no_text ->
          stream
      end

    Enum.reduce(delta["tool_calls"] || [], stream, &receive_tool_call/2)
  end

  # A tool call arrives in fragments keyed by `index`: the first carries its
  # id and name, the rest pieces of its JSON arguments.
  defp receive_tool_call(%{"index" => index} = fragment, stream) do
    function = fragment["function"] || %{}
    call = Map.get(stream.calls, index, %{id: nil, name: "", args: []})

    call = %{
      id: fragment["id"] || call.id,
      name: call.name <> (function["name"] || ""),
      args: [call.args, function["arguments"] || ""]
    }

    %{stream | calls: Map.put(stream.calls, index, call)}
  end

  defp finish({:ok, %Req.Response{status: status} = resp}, initial) do
    stream = Req.Response.get_private(resp, :stream, initial)

    cond do
      status not in 200..299 ->
        {:error, {:http_status, status, IO.iodata_to_binary(stream.error_body)}}

      stream.error ->
        {:error, stream.error}

      true ->
        reply(stream)
    end
  end

  defp finish({:error, %Req.TransportError{reason: reason}}, _initial),
    do: {:error, {:transport_error, reason}}

  defp finish({:error, exception}, _initial), do: {:error, Exception.message(exception)}

  defp reply(stream) do
    calls =
      stream.calls
      |> Enum.sort_by(fn {index, _call} -> index end)
      |> Enum.map(fn {_index, call} -> call end)

    with {:ok, tool_calls} <- decode_tool_calls(calls) do
      {:ok,
       %{
         text: IO.iodata_to_binary(stream.text),
         tool_calls: tool_calls,
         usage: usage(stream.usage)
       }}
    end
  end

  defp decode_tool_calls(calls) do
    Enum.reduce_while(calls, {:ok, []}, fn call, {:ok, acc} ->
      case decode_args(IO.iodata_to_binary(call.args)) do
        {:ok, args} ->
          {:cont, {:ok, acc ++ [%{id: call.id, name: call.name, args: args}]}}

        :error ->
          {:halt, {:error, {:invalid_tool_arguments, call.name, IO.iodata_to_binary(call.args)}}}
      end
    end)
  end

  defp decode_args(""), do: {:ok, %{}}

  defp decode_args(json) do
    case Jason.decode(json) do
      {:ok, %{} = args} -> {:ok, args}
      _invalid -> :error
    end
  end

  defp usage(nil), do: %{input_tokens: 0, output_tokens: 0}

  defp usage(usage) do
    %{
      input_tokens: usage["prompt_tokens"] || 0,
      output_tokens: usage["completion_tokens"] || 0
    }
  end
end
