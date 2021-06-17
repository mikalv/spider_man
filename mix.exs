defmodule SpiderMan.MixProject do
  use Mix.Project

  def project do
    [
      app: :spider_man,
      description: "SpiderMan,a fast high-level web crawling & scraping framework for Elixir",
      version: "0.1.0",
      elixir: "~> 1.11",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      test_coverage: [ignore_modules: cover_ignore_modules()],
      deps: deps(),
      package: package()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {SpiderMan.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:broadway, "~> 0.6"},
      {:tesla, "~> 1.4"},
      {:finch, "~> 0.6"},
      {:logger_file_backend, "~> 0.0.11"},
      {:nimble_options, "~> 0.3"},
      {:jason, "~> 1.2", optional: true},
      {:nimble_csv, "~> 1.1", optional: true},
      {:hackney, "~> 1.7", optional: true},
      {:telemetry_metrics, "~> 0.6", optional: true}
    ]
  end

  defp cover_ignore_modules do
    [
      SpiderMan.Requester.JustReturn,
      SpiderMan.Pipeline.Standard,
      SpiderMan.Pipeline.Empty,
      SpiderMan.Pipeline.OnlyCall,
      SpiderMan.Pipeline.NoCallFunction,
      SpiderMan.Modules,
      SpiderManTest,
      EngineTest,
      Spider0
    ]
  end

  defp package do
    [
      name: "spider_man",
      files: ["lib", "mix.exs", "README.md", "LICENSE"],
      maintainers: ["feng19"],
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => "https://github.com/feng19/spider_man"}
    ]
  end
end
