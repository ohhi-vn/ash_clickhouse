defmodule AshClickhouse.MixProject do
  use Mix.Project

  def project do
    [
      app: :ash_clickhouse,
      version: "0.4.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      test_paths: ["test"],
      test_load_filters: [&String.ends_with?(&1, "_test.exs")],
      test_ignore_filters: [&String.starts_with?(&1, "test/support/")],
      dialyzer: [
        plt_add_apps: [:ex_unit, :mix],
        flags: [:unmatched_returns, :error_handling, :underspecs]
      ],
      name: "AshClickhouse",
      source_url: "https://github.com/ohhi-vn/ash_clickhouse",
      homepage_url: "https://ohhi.vn",
      docs: docs(),
      package: package(),
      elixirc_paths: elixirc_paths(Mix.env()),
      test_coverage: [
        tool: Mix.Tasks.Test.Coverage,
        output: "cover",
        summary: [threshold: 85]
      ],
      consolidate_protocols: Mix.env() != :test,
      test_elixirc_options: [debug_info: true]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {AshClickhouse.Application, []}
    ]
  end

  defp package do
    [
      description: "An Ash Framework data layer for ClickHouse",
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => "https://github.com/ohhi-vn/ash_clickhouse",
        "Documentation" => "https://hexdocs.pm/ash_clickhouse",
        "ClickHouse" => "https://clickhouse.com/",
        "Ash Framework" => "https://ash-hq.org/"
      },
      files: ~w(lib .formatter.exs mix.exs README* LICENSE* CHANGELOG.md)
    ]
  end

  defp docs do
    [
      main: "AshClickhouse",
      extras: [
        "README.md",
        "CHANGELOG.md",
        "guides/getting-started.md",
        "guides/resources.md",
        "guides/configuration.md",
        "guides/migrations.md",
        "guides/querying.md",
        "guides/multitenancy.md",
        "guides/types.md",
        "guides/telemetry.md",
        "guides/limitations.md"
      ],
      groups_for_extras: [
        Guides: [
          "guides/getting-started.md",
          "guides/resources.md",
          "guides/configuration.md",
          "guides/migrations.md",
          "guides/querying.md",
          "guides/multitenancy.md",
          "guides/types.md",
          "guides/telemetry.md",
          "guides/limitations.md"
        ]
      ],
      groups_for_modules: [
        Core: [
          AshClickhouse,
          AshClickhouse.DataLayer,
          AshClickhouse.Query
        ],
        "Schema Helpers": [
          AshClickhouse.Migration
        ],
        "Data Layer Modules": [
          AshClickhouse.DataLayer.Dsl,
          AshClickhouse.DataLayer.QueryBuilder,
          AshClickhouse.DataLayer.Types
        ],
        "Repo Helpers": [
          AshClickhouse.Repo
        ],
        Observability: [
          AshClickhouse.Telemetry
        ],
        "Error Handling": [
          AshClickhouse.Error
        ]
      ]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ash, "~> 3.29"},
      {:clickhouse, "~> 0.32"},
      {:telemetry, "~> 1.0"},
      {:jason, "~> 1.0", optional: true},
      {:decimal, "~> 3.1", optional: true},
      {:testcontainer_ex, "== 0.7.2", only: [:test], runtime: false},

      # Dev / docs
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},

      # Code quality
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_dna, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      "test.ci": ["credo --strict", "test --exclude integration"],
      test: ["test --exclude integration"],
      "test.unit": ["test --exclude integration"],
      "test.integration": ["test --only integration"],
      "test.integration.direct": [
        "test --only integration --seed 0"
      ],
      "test.integration.apple_container": [
        "run --eval \"System.put_env(\"CONTAINER_ENGINE\", \"apple_container\")\"",
        "test --only integration"
      ],
      # Testing & Coverage
      coveralls: ["test --cover", "coveralls.html"],
      # Code Quality
      quality: ["format --check-formatted", "credo --strict", "dialyzer"]
    ]
  end
end
