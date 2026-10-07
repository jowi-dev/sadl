import Config

# Tests start their own listeners on temporary paths rather than binding the
# real socket in $XDG_RUNTIME_DIR, and keep the application's store in memory
# rather than writing to $XDG_DATA_HOME.
if config_env() == :test do
  config :sadld, listen: false, store_path: ":memory:"
end
