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
    "ghcr.io/rsolv-dev/rsolv-sandbox@sha256:5da39b54d8ac6784da5bd3bb3fa769f0c865ba6d381598718f8066a57f698769"

import_config "#{config_env()}.exs"
