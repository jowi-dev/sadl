defmodule Sadld.Provider.OpenAITest do
  use ExUnit.Case, async: true

  alias Sadld.Provider.OpenAI

  @key "sk-test-secret"

  defp opts(extra \\ []) do
    test_pid = self()

    Keyword.merge(
      [
        api_key: @key,
        model: "test-model",
        on_text: &send(test_pid, {:text, &1}),
        req_options: [plug: {Req.Test, __MODULE__}]
      ],
      extra
    )
  end

  # Answers with an SSE stream, one HTTP chunk per element of `chunks`.
  defp stream(conn, chunks) do
    conn =
      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_chunked(200)

    Enum.reduce(chunks, conn, fn chunk, conn ->
      {:ok, conn} = Plug.Conn.chunk(conn, chunk)
      conn
    end)
  end

  defp event(data), do: "data: #{Jason.encode!(data)}\n\n"

  defp delta(delta), do: event(%{choices: [%{index: 0, delta: delta}]})

  defp usage(input, output) do
    event(%{choices: [], usage: %{prompt_tokens: input, completion_tokens: output}})
  end

  # Stubs one request: sends its decoded body to the test and answers with
  # `chunks`.
  defp stub_stream(chunks) do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request, conn, Jason.decode!(body)})
      stream(conn, chunks)
    end)
  end

  test "streams text as it arrives and reports usage at the end" do
    whole = delta(%{role: "assistant", content: "Hel"}) <> delta(%{content: "lo"})
    <<first::binary-size(30), rest::binary>> = whole
    stub_stream([first, rest, usage(12, 5), "data: [DONE]\n\n"])

    assert OpenAI.chat([%{role: :user, content: "hi"}], opts()) ==
             {:ok, %{text: "Hello", tool_calls: [], usage: %{input_tokens: 12, output_tokens: 5}}}

    assert_received {:text, "Hel"}
    assert_received {:text, "lo"}
  end

  test "posts a streaming chat completion with bearer auth" do
    stub_stream([delta(%{content: "ok"}), "data: [DONE]\n\n"])

    {:ok, _reply} = OpenAI.chat([%{role: :user, content: "hi"}], opts())

    assert_received {:request, conn, body}
    assert conn.method == "POST"
    assert conn.request_path == "/api/v1/chat/completions"
    assert conn.host == "api.venice.ai"
    assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer #{@key}"]

    assert body == %{
             "model" => "test-model",
             "stream" => true,
             "stream_options" => %{"include_usage" => true},
             "messages" => [%{"role" => "user", "content" => "hi"}]
           }
  end

  test "sends the system prompt as the first message" do
    stub_stream(["data: [DONE]\n\n"])

    {:ok, _reply} = OpenAI.chat([%{role: :user, content: "hi"}], opts(system: "Be brief."))

    assert_received {:request, _conn, body}

    assert body["messages"] == [
             %{"role" => "system", "content" => "Be brief."},
             %{"role" => "user", "content" => "hi"}
           ]
  end

  test "uses the configured base URL and falls back to the default model" do
    stub_stream(["data: [DONE]\n\n"])

    opts = opts(base_url: "http://localhost:11434/v1") |> Keyword.delete(:model)
    {:ok, _reply} = OpenAI.chat([%{role: :user, content: "hi"}], opts)

    assert_received {:request, conn, body}
    assert conn.host == "localhost"
    assert conn.port == 11_434
    assert conn.request_path == "/v1/chat/completions"
    assert body["model"] == OpenAI.default_model()
  end

  test "assembles tool calls streamed in fragments across chunks" do
    stub_stream([
      delta(%{
        tool_calls: [
          %{index: 0, id: "call_a", type: "function", function: %{name: "read", arguments: ""}}
        ]
      }),
      delta(%{tool_calls: [%{index: 0, function: %{arguments: "{\"pa"}}]}),
      delta(%{
        tool_calls: [
          %{index: 1, id: "call_b", type: "function", function: %{name: "bash", arguments: ""}}
        ]
      }),
      delta(%{tool_calls: [%{index: 0, function: %{arguments: "th\":\"a.txt\"}"}}]}),
      delta(%{tool_calls: [%{index: 1, function: %{arguments: "{}"}}]}),
      event(%{choices: [%{index: 0, delta: %{}, finish_reason: "tool_calls"}]}),
      usage(7, 3),
      "data: [DONE]\n\n"
    ])

    assert {:ok, reply} = OpenAI.chat([%{role: :user, content: "go"}], opts())

    assert reply == %{
             text: "",
             tool_calls: [
               %{id: "call_a", name: "read", args: %{"path" => "a.txt"}},
               %{id: "call_b", name: "bash", args: %{}}
             ],
             usage: %{input_tokens: 7, output_tokens: 3}
           }

    refute_received {:text, _text}
  end

  test "sends prior tool calls, tool results and tool definitions" do
    stub_stream(["data: [DONE]\n\n"])

    messages = [
      %{role: :user, content: "read it"},
      %{
        role: :assistant,
        content: "",
        tool_calls: [%{id: "call_a", name: "read", args: %{"path" => "a.txt"}}]
      },
      %{role: :tool, call_id: "call_a", content: "contents", is_error: false},
      %{role: :assistant, content: "done", tool_calls: []}
    ]

    tool = %{
      name: "read",
      description: "Read a file",
      parameters: %{type: "object", properties: %{path: %{type: "string"}}}
    }

    {:ok, _reply} = OpenAI.chat(messages, opts(tools: [tool]))

    assert_received {:request, _conn, body}

    assert body["messages"] == [
             %{"role" => "user", "content" => "read it"},
             %{
               "role" => "assistant",
               "content" => nil,
               "tool_calls" => [
                 %{
                   "id" => "call_a",
                   "type" => "function",
                   "function" => %{"name" => "read", "arguments" => ~s({"path":"a.txt"})}
                 }
               ]
             },
             %{"role" => "tool", "tool_call_id" => "call_a", "content" => "contents"},
             %{"role" => "assistant", "content" => "done"}
           ]

    assert body["tools"] == [
             %{
               "type" => "function",
               "function" => %{
                 "name" => "read",
                 "description" => "Read a file",
                 "parameters" => %{
                   "type" => "object",
                   "properties" => %{"path" => %{"type" => "string"}}
                 }
               }
             }
           ]
  end

  test "reports zero usage when the stream carries none" do
    stub_stream([delta(%{content: "hi"}), "data: [DONE]\n\n"])

    assert {:ok, %{usage: %{input_tokens: 0, output_tokens: 0}}} =
             OpenAI.chat([%{role: :user, content: "hi"}], opts())
  end

  test "fails on tool call arguments that are not a JSON object" do
    stub_stream([
      delta(%{tool_calls: [%{index: 0, id: "c", function: %{name: "read", arguments: "{oops"}}]}),
      "data: [DONE]\n\n"
    ])

    assert {:error, {:invalid_tool_arguments, "read", "{oops"}} =
             OpenAI.chat([%{role: :user, content: "hi"}], opts())
  end

  test "fails with the status and body of an unsuccessful response" do
    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_status(401)
      |> Req.Test.json(%{error: %{message: "bad key"}})
    end)

    assert {:error, {:http_status, 401, body}} =
             OpenAI.chat([%{role: :user, content: "hi"}], opts())

    assert body =~ "bad key"
    refute_received {:text, _text}
  end

  test "fails with the message of an error event in the stream" do
    stub_stream([
      delta(%{content: "par"}),
      event(%{error: %{message: "overloaded"}})
    ])

    assert OpenAI.chat([%{role: :user, content: "hi"}], opts()) ==
             {:error, {:api_error, "overloaded"}}
  end

  test "fails with the reason of a transport error" do
    Req.Test.stub(__MODULE__, &Req.Test.transport_error(&1, :econnrefused))

    assert OpenAI.chat([%{role: :user, content: "hi"}], opts()) ==
             {:error, {:transport_error, :econnrefused}}
  end

  test "keeps the API key out of error reasons" do
    Req.Test.stub(__MODULE__, fn conn ->
      conn |> Plug.Conn.put_status(500) |> Req.Test.text("boom")
    end)

    {:error, reason} = OpenAI.chat([%{role: :user, content: "hi"}], opts())
    refute inspect(reason) =~ @key
  end
end
