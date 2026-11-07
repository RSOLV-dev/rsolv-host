import Config

config :rsolv_host,
  run_cli: config_env() == :prod,
  api_url: "https://api.rsolv.ai.",
  oidc_audience: "https://api.rsolv.dev"

import_config "#{config_env()}.exs"
