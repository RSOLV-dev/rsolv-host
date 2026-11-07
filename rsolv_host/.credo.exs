%{
  configs: [
    %{
      name: "default",
      files: %{included: ["lib/", "test/"]},
      strict: true,
      checks: [{Credo.Check.Readability.Specs, files: %{excluded: ["test/"]}}]
    }
  ]
}
