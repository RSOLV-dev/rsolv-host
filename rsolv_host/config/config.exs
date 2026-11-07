import Config

config :rsolv_host,
  run_cli: config_env() == :prod,
  api_url: "https://api.rsolv.ai.",
  oidc_audience: "https://api.rsolv.dev",
  proxy_image:
    "ubuntu/squid:latest@sha256:6a097f68bae708cedbabd6188d68c7e2e7a38cedd05a176e1cc0ba29e3bbe029",
  # All zeroes until step 3d publishes the image; Sandbox.start/1 refuses it.
  sandbox_image: "ghcr.io/rsolv-dev/rsolv-sandbox@sha256:" <> String.duplicate("0", 64)

import_config "#{config_env()}.exs"
