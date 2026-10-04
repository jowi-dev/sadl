import Config

# Tests start their own listeners on temporary paths rather than binding the
# real socket in $XDG_RUNTIME_DIR.
if config_env() == :test do
  config :sadld, listen: false
end
