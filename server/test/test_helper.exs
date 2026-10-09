# The sidecar tests run the Bun plugin host, borrowing zod from the thatch
# package the dev shell names in SADL_THATCH_PLUGIN.
sidecar? = System.find_executable("bun") != nil and System.get_env("SADL_THATCH_PLUGIN") != nil

ExUnit.start(exclude: if(sidecar?, do: [], else: [:sidecar]))
