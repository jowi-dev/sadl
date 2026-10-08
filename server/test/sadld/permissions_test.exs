defmodule Sadld.PermissionsTest do
  use ExUnit.Case, async: true

  alias Sadld.Permissions

  defp call(name, args \\ %{}), do: %{id: "c_1", name: name, args: args}

  defp policy!(map) do
    {:ok, policy} = Permissions.parse(map)
    policy
  end

  describe "check/2" do
    test "the allow-all policy allows every call" do
      assert Permissions.check(Permissions.allow_all(), call("write")) == :allow

      assert Permissions.check(Permissions.allow_all(), call("bash", %{"command" => "rm"})) ==
               :allow
    end

    test "falls back to the default when no rule matches" do
      policy =
        policy!(%{"default" => "ask", "rules" => [%{"tool" => "read", "action" => "allow"}]})

      assert Permissions.check(policy, call("read")) == :allow
      assert Permissions.check(policy, call("write")) == :ask
    end

    test "the first matching rule wins" do
      policy =
        policy!(%{
          "default" => "allow",
          "rules" => [
            %{"tool" => "bash", "command" => "git status*", "action" => "allow"},
            %{"tool" => "bash", "command" => "git *", "action" => "ask"},
            %{"tool" => "bash", "action" => "deny"}
          ]
        })

      assert Permissions.check(policy, call("bash", %{"command" => "git status -s"})) == :allow
      assert Permissions.check(policy, call("bash", %{"command" => "git push"})) == :ask
      assert Permissions.check(policy, call("bash", %{"command" => "rm -rf /"})) == :deny
    end

    test "a command pattern matches the whole command, with * matching anything" do
      policy =
        policy!(%{
          "default" => "deny",
          "rules" => [%{"tool" => "bash", "command" => "ls*", "action" => "allow"}]
        })

      assert Permissions.check(policy, call("bash", %{"command" => "ls"})) == :allow
      assert Permissions.check(policy, call("bash", %{"command" => "ls -la\n/tmp"})) == :allow
      assert Permissions.check(policy, call("bash", %{"command" => "echo; ls"})) == :deny
    end

    test "pattern characters other than * are literal" do
      policy =
        policy!(%{
          "default" => "deny",
          "rules" => [%{"tool" => "bash", "command" => "cat a.txt", "action" => "allow"}]
        })

      assert Permissions.check(policy, call("bash", %{"command" => "cat a.txt"})) == :allow
      assert Permissions.check(policy, call("bash", %{"command" => "cat abtxt"})) == :deny
    end

    test "a command rule does not match a call without a string command" do
      policy =
        policy!(%{
          "default" => "deny",
          "rules" => [%{"tool" => "bash", "command" => "*", "action" => "allow"}]
        })

      assert Permissions.check(policy, call("bash", %{})) == :deny
      assert Permissions.check(policy, call("bash", %{"command" => 1})) == :deny
      assert Permissions.check(policy, call("bash", "not an object")) == :deny
    end
  end

  describe "parse/1" do
    test "rules default to none" do
      assert {:ok, policy} = Permissions.parse(%{"default" => "ask"})
      assert Permissions.check(policy, call("read")) == :ask
    end

    test "rejects a policy that is not an object" do
      assert Permissions.parse([]) == {:error, "the policy must be a JSON object"}
    end

    test "rejects a missing or unknown default" do
      assert Permissions.parse(%{}) ==
               {:error, "`default` must be one of \"allow\", \"ask\", \"deny\""}

      assert Permissions.parse(%{"default" => "maybe"}) ==
               {:error, "`default` must be one of \"allow\", \"ask\", \"deny\""}
    end

    test "rejects rules that are not a list" do
      assert Permissions.parse(%{"default" => "ask", "rules" => %{}}) ==
               {:error, "`rules` must be a list"}
    end

    test "rejects a malformed rule, naming its index" do
      bad_rules = [
        {"x", "rule 0: must be an object"},
        {%{"action" => "allow"}, "rule 0: `tool` must be a string"},
        {%{"tool" => "read"}, "rule 0: `action` must be one of \"allow\", \"ask\", \"deny\""},
        {%{"tool" => "bash", "command" => 1, "action" => "ask"},
         "rule 0: `command` must be a string"},
        {%{"tool" => "read", "command" => "x", "action" => "ask"},
         "rule 0: `command` only applies to the bash tool"}
      ]

      for {rule, message} <- bad_rules do
        assert Permissions.parse(%{"default" => "ask", "rules" => [rule]}) == {:error, message}
      end
    end
  end

  describe "load/1" do
    @tag :tmp_dir
    test "reads the policy from a JSON file", %{tmp_dir: dir} do
      path = Path.join(dir, "permissions.json")
      File.write!(path, ~s({"default": "deny", "rules": [{"tool": "read", "action": "allow"}]}))

      assert {:ok, policy} = Permissions.load(path)
      assert Permissions.check(policy, call("read")) == :allow
      assert Permissions.check(policy, call("edit")) == :deny
    end

    @tag :tmp_dir
    test "allows everything when the file does not exist", %{tmp_dir: dir} do
      assert Permissions.load(Path.join(dir, "missing.json")) == {:ok, Permissions.allow_all()}
    end

    @tag :tmp_dir
    test "fails on a file that is not valid JSON or not a valid policy", %{tmp_dir: dir} do
      path = Path.join(dir, "permissions.json")

      File.write!(path, "{")
      assert {:error, "#{path}: invalid JSON"} == Permissions.load(path)

      File.write!(path, ~s({"default": "sometimes"}))

      assert {:error, "#{path}: `default` must be one of \"allow\", \"ask\", \"deny\""} ==
               Permissions.load(path)
    end
  end

  test "default_path/0 is permissions.json in the config directory" do
    assert Permissions.default_path() == Path.join(Sadld.config_dir(), "permissions.json")
  end
end
