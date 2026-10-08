import Config

# Tests start their own listeners on temporary paths rather than binding the
# real socket in $XDG_RUNTIME_DIR, keep the application's store in memory
# rather than writing to $XDG_DATA_HOME, never read the user's permission
# policy, so sessions they open allow every tool call, and load no plugins,
# so sessions do not start the thatch sidecar the dev shell names.
if config_env() == :test do
  config :sadld,
    listen: false,
    store_path: ":memory:",
    permissions_path: Path.join(System.tmp_dir!(), "sadld-test-no-such-permissions.json"),
    plugins: []
end
