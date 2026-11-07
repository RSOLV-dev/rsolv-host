import Config

config :rsolv_host, exec: RsolvHost.FakeExec

config :rsolv_host, RsolvHost.Platform,
  req_options: [plug: {Req.Test, RsolvHost.Platform}, retry: false]

config :rsolv_host, RsolvHost.Oidc, req_options: [plug: {Req.Test, RsolvHost.Oidc}, retry: false]

config :rsolv_host, RsolvHost.GitHub,
  req_options: [plug: {Req.Test, RsolvHost.GitHub}, retry: false]

config :rsolv_host,
  sandbox_image: "ghcr.io/rsolv-dev/rsolv-sandbox@sha256:" <> String.duplicate("1", 64)
