defmodule AshClickhouse.MixProject do
  use Mix.Project

  def project do
    [
      app: :ash_clickhouse,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "An Ash Framework data layer for ClickHouse",
      source_url: "https://github.com/ohhi-vn/ash_clickhouse",
      homepage_url: "https://github.com/ohhi-vn/ash_clickhouse",
      package: package(),
      docs: docs(),
      aliases: aliases(),
      test_paths: ["test"],
      test_load_filters: [&String.ends_with?(&1, "_test.exs")],
      test_ignore_filters: [&String.starts_with?(&1, "test/support/")],
      elixirc_paths: elixirc_paths(Mix.env()),
      consolidate_protocols: Mix.env() != :test
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp package do
    [
      name: "ash_clickhouse",
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => "https://github.com/ohhi-vn/ash_clickhouse",
        "Changelog" => "https://github.com/ohhi-vn/ash_clickhouse/blob/main/CHANGELOG.md"
      },
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE CHANGELOG.md)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "CHANGELOG.md"],
      source_ref: "main"
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ash, "~> 3.0"},
      {:clickhouse, "~> 0.32"},
      {:telemetry, "~> 1.0"},
      {:jason, "~> 1.0", optional: true},
      {:decimal, "~> 2.0", optional: true},
      {:testcontainer_ex, "== 0.7.2", only: [:test], runtime: false}
    ]
  end

  defp aliases do
    [
      "test.ci": ["test --exclude integration"],
      test: ["test --exclude integration"],
      "test.unit": ["test --exclude integration"],
      "test.integration": ["test --only integration"],
      "test.integration.direct": [
        "test --only integration --seed 0"
      ],
      "test.integration.apple_container": [
        "run --eval \"System.put_env(\"CONTAINER_ENGINE\", \"apple_container\")\"",
        "test --only integration"
      ]
    ]
  end
end
