defmodule Sadld.CompactionTest do
  use ExUnit.Case, async: true

  alias Sadld.Compaction
  alias Sadld.Test.StubProvider

  @usage %{input_tokens: 7, output_tokens: 5}

  # A message whose content estimates at `tokens` tokens.
  defp user(tokens), do: %{role: :user, content: String.duplicate("x", tokens * 4)}

  defp assistant(tokens),
    do: %{role: :assistant, content: String.duplicate("y", tokens * 4), tool_calls: []}

  defp call_step(id) do
    [
      %{
        role: :assistant,
        content: "",
        tool_calls: [%{id: id, name: "read", args: %{"path" => "a"}}]
      },
      %{role: :tool, call_id: id, content: String.duplicate("z", 400), is_error: false}
    ]
  end

  defp provider(respond), do: {StubProvider, respond: respond, model: "m", system: "agent prompt"}

  describe "estimate_tokens/1" do
    test "counts about four characters per token, rounding up" do
      assert Compaction.estimate_tokens(user(10)) == 10
      assert Compaction.estimate_tokens(%{role: :user, content: "abcde"}) == 2
    end

    test "counts tool call arguments and sums lists" do
      [call, result] = call_step("c1")
      assert Compaction.estimate_tokens(call) > 0
      assert Compaction.estimate_tokens(result) == 100
      assert Compaction.estimate_tokens([call, result]) == Compaction.estimate_tokens(call) + 100
    end
  end

  describe "needed?/2" do
    test "is true once the context leaves less than the reserve free" do
      opts = [context_window: 1_000, reserve_tokens: 200]
      refute Compaction.needed?(800, opts)
      assert Compaction.needed?(801, opts)
    end
  end

  describe "cut_point/3" do
    test "keeps at least keep_recent_tokens of the newest messages" do
      messages = [user(50), assistant(50), user(50), assistant(50)]
      assert Compaction.cut_point(messages, 0, 60) == 2
      assert Compaction.cut_point(messages, 0, 100) == 2
      assert Compaction.cut_point(messages, 0, 101) == 1
    end

    test "never cuts between an assistant message and its tool results" do
      messages = [user(50)] ++ call_step("c1") ++ [assistant(10)]
      # The tool result alone reaches the budget; the cut moves back to its call.
      assert Compaction.cut_point(messages, 0, 105) == 1
    end

    test "is nil when the tail kept would leave nothing new to summarize" do
      messages = [user(50), assistant(50), user(50), assistant(50)]
      assert Compaction.cut_point(messages, 2, 60) == nil
      assert Compaction.cut_point(messages, 0, 1_000) == nil
    end
  end

  describe "context/2" do
    test "is the messages themselves without a compaction" do
      messages = [user(1), assistant(1)]
      assert Compaction.context(messages, nil) == messages
    end

    test "replaces the messages before first_kept with the summary" do
      messages = [user(1), assistant(1), user(2), assistant(2)]

      assert [summary | rest] =
               Compaction.context(messages, %{summary: "they said hi", first_kept: 2})

      assert rest == Enum.drop(messages, 2)
      assert %{role: :user, content: content} = summary
      assert content =~ "they said hi"
    end
  end

  describe "summarize/3" do
    test "asks the provider for a summary of the serialized conversation, without tools" do
      test_pid = self()

      respond = fn messages, _on_text, opts ->
        send(test_pid, {:asked, messages, opts})
        {:ok, %{text: "the summary", tool_calls: [], usage: @usage}}
      end

      messages = [%{role: :user, content: "fix the bug"}] ++ call_step("c1")

      assert Compaction.summarize(messages, nil, provider(respond)) ==
               {:ok, "the summary", @usage}

      assert_receive {:asked, [%{role: :user, content: prompt}], opts}
      assert prompt =~ "fix the bug"
      assert prompt =~ "read"
      assert opts[:tools] == []
      assert opts[:model] == "m"
      assert opts[:system] != "agent prompt"
    end

    test "folds in the previous summary" do
      test_pid = self()

      respond = fn [%{content: prompt}] ->
        send(test_pid, {:prompt, prompt})
        {:ok, %{text: "new", tool_calls: [], usage: @usage}}
      end

      assert {:ok, "new", _usage} =
               Compaction.summarize([user(1)], "earlier work", provider(respond))

      assert_receive {:prompt, prompt}
      assert prompt =~ "earlier work"
    end

    test "passes provider errors through" do
      respond = fn _messages -> {:error, :boom} end
      assert Compaction.summarize([user(1)], nil, provider(respond)) == {:error, :boom}
    end
  end

  describe "compact/4" do
    @opts [keep_recent_tokens: 60]

    test "summarizes the messages before the cut, after any earlier compaction" do
      test_pid = self()

      respond = fn [%{content: prompt}] ->
        send(test_pid, {:prompt, prompt})
        {:ok, %{text: "summary 2", tool_calls: [], usage: @usage}}
      end

      messages = [
        %{role: :user, content: "first ask"},
        assistant(1),
        %{role: :user, content: "second ask"},
        assistant(1),
        user(50),
        assistant(50)
      ]

      previous = %{summary: "summary 1", first_kept: 2}

      assert Compaction.compact(messages, previous, provider(respond), @opts) ==
               {:ok, %{summary: "summary 2", first_kept: 4}, @usage}

      assert_receive {:prompt, prompt}
      assert prompt =~ "second ask"
      refute prompt =~ "first ask"
      assert prompt =~ "summary 1"
    end

    test "is :noop when nothing falls before the tail kept" do
      respond = fn _messages -> flunk("summarized") end
      messages = [user(50), assistant(50)]
      assert Compaction.compact(messages, nil, provider(respond), @opts) == :noop
    end

    test "with force: true summarizes everything when the tail would keep it all" do
      respond = fn _messages -> {:ok, %{text: "all of it", tool_calls: [], usage: @usage}} end
      messages = [user(5), assistant(5)]

      assert Compaction.compact(messages, nil, provider(respond), [force: true] ++ @opts) ==
               {:ok, %{summary: "all of it", first_kept: 2}, @usage}

      compacted = %{summary: "all of it", first_kept: 2}
      assert Compaction.compact(messages, compacted, provider(respond), force: true) == :noop
    end
  end
end
