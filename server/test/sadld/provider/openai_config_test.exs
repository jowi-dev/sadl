defmodule Sadld.Provider.OpenAIConfigTest do
  # Changes the OS environment and application env, so not async.
  use ExUnit.Case, async: false

  alias Sadld.Provider.OpenAI

  @env "VENICE_API_KEY"

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    saved_key = System.get_env(@env)
    System.delete_env(@env)

    on_exit(fn ->
      if saved_key, do: System.put_env(@env, saved_key), else: System.delete_env(@env)
      Application.delete_env(:sadld, OpenAI)
    end)

    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(test_pid, {:authorization, Plug.Conn.get_req_header(conn, "authorization")})
      {:ok, body, _conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:model, Jason.decode!(body)["model"]})
      Req.Test.text(conn, "data: [DONE]\n\n")
    end)

    %{key_file: Path.join(tmp_dir, "api_key")}
  end

  defp chat(opts) do
    opts =
      Keyword.merge([on_text: fn _ -> :ok end, req_options: [plug: {Req.Test, __MODULE__}]], opts)

    OpenAI.chat([%{role: :user, content: "hi"}], opts)
  end

  test "reads the API key from VENICE_API_KEY", %{key_file: key_file} do
    File.write!(key_file, "from-file\n")
    System.put_env(@env, "from-env")

    assert {:ok, _reply} = chat(api_key_file: key_file)
    assert_received {:authorization, ["Bearer from-env"]}
  end

  test "falls back to the key file, trimmed", %{key_file: key_file} do
    File.write!(key_file, "  from-file\n")

    assert {:ok, _reply} = chat(api_key_file: key_file)
    assert_received {:authorization, ["Bearer from-file"]}
  end

  test "takes the key file and model from the application env", %{key_file: key_file} do
    File.write!(key_file, "from-app-env")
    Application.put_env(:sadld, OpenAI, api_key_file: key_file, model: "configured-model")

    assert {:ok, _reply} = chat([])
    assert_received {:authorization, ["Bearer from-app-env"]}
    assert_received {:model, "configured-model"}
  end

  test "fails without a key and makes no request", %{key_file: key_file} do
    assert chat(api_key_file: key_file) == {:error, :missing_api_key}
    refute_received {:authorization, _header}
  end

  test "an empty key file counts as no key", %{key_file: key_file} do
    File.write!(key_file, "\n")
    assert chat(api_key_file: key_file) == {:error, :missing_api_key}
  end

  test "the default key file lives under $XDG_CONFIG_HOME/sadl", %{tmp_dir: tmp_dir} do
    saved = System.get_env("XDG_CONFIG_HOME")
    System.put_env("XDG_CONFIG_HOME", tmp_dir)

    on_exit(fn ->
      if saved,
        do: System.put_env("XDG_CONFIG_HOME", saved),
        else: System.delete_env("XDG_CONFIG_HOME")
    end)

    assert OpenAI.default_api_key_file() == Path.join([tmp_dir, "sadl", "api_key"])
  end
end
