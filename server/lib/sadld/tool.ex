defmodule Sadld.Tool do
  @moduledoc """
  One tool the model can call, such as `read` or `edit`. `Sadld.Tools`
  collects them, exposes their specs to the provider and dispatches calls.

  Also holds the helpers tools share for checking arguments and resolving
  paths. Every failure is returned as `{:error, message}` for the model to
  read; a tool never raises on bad input.
  """

  @typedoc """
  What the model is told about a tool: its name, a description and a JSON
  schema for its argument object.
  """
  @type spec :: %{name: String.t(), description: String.t(), parameters: map()}

  @doc "Describes the tool to the model."
  @callback spec() :: spec()

  @doc """
  Runs the tool with `args`, the decoded argument object from the model,
  in the session's working directory `cwd`.
  """
  @callback run(args :: map(), cwd :: String.t()) :: {:ok, String.t()} | {:error, String.t()}

  @doc "Resolves `path` against `cwd`. Absolute paths are kept as they are."
  @spec resolve(String.t(), String.t()) :: String.t()
  def resolve(path, cwd), do: Path.expand(path, cwd)

  @doc "Fetches the required string argument `key`."
  @spec string(map(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def string(args, key) do
    case Map.fetch(args, key) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      {:ok, _value} -> {:error, "`#{key}` must be a string"}
      :error -> {:error, "missing required argument `#{key}`"}
    end
  end

  @doc "Fetches the optional positive integer argument `key`, or `default`."
  @spec pos_integer(map(), String.t(), pos_integer()) ::
          {:ok, pos_integer()} | {:error, String.t()}
  def pos_integer(args, key, default) do
    case Map.get(args, key) do
      nil -> {:ok, default}
      value when is_integer(value) and value > 0 -> {:ok, value}
      _value -> {:error, "`#{key}` must be a positive integer"}
    end
  end

  @doc "Reads the UTF-8 text file at `path`."
  @spec read_text(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def read_text(path) do
    case File.read(path) do
      {:ok, text} ->
        if String.valid?(text),
          do: {:ok, text},
          else: {:error, "#{path} is not a UTF-8 text file"}

      {:error, reason} ->
        file_error(path, reason)
    end
  end

  @doc "Describes a `File` error `reason` for `path`."
  @spec file_error(String.t(), File.posix() | atom()) :: {:error, String.t()}
  def file_error(path, :eisdir), do: {:error, "#{path} is a directory"}
  def file_error(path, reason), do: {:error, "#{path}: #{:file.format_error(reason)}"}
end
