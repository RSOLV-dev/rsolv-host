import Config

config :rsolv_host,
  run_cli: config_env() == :prod,
  api_url: "https://api.rsolv.ai.",
  oidc_audience: "https://api.rsolv.dev",
  proxy_image:
    "ubuntu/squid:latest@sha256:6a097f68bae708cedbabd6188d68c7e2e7a38cedd05a176e1cc0ba29e3bbe029",
  # sandbox-v0.1.0 (rsolv-action b2b4373a), written by rsolv-action scripts/pin-sandbox.sh
  # after its provenance verified. Sandbox.start/1 refuses an all-zero digest.
  sandbox_image:
    "ghcr.io/rsolv-dev/rsolv-sandbox@sha256:3ce7cbb8e7caf0be6d16abe416293348819b3b8a7d3c6b1abadcfe6b797a9e6b"

import_config "#{config_env()}.exs"
