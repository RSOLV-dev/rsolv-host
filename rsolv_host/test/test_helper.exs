{:ok, _registry} = RsolvHost.FakeExec.start()
ExUnit.start(exclude: [:docker])
