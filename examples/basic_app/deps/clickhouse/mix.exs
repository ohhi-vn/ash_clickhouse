defmodule ClickHouse.MixProject do
  use Mix.Project

  @version "0.32.0"

  def project do
    [
      app: :clickhouse,
      version: @version,
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      name: "ClickHouse",
      docs: docs(),
      aliases: aliases(),
      preferred_cli_env: preferred_cli_env()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp description do
    """
    A ClickHouse database client.
    """
  end

  defp package do
    [
      files: ["lib", "mix.exs", "README*"],
      maintainers: ["Nicholas Sweeting"],
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/nsweeting/clickhouse"}
    ]
  end

  defp docs do
    [
      extras: ["README.md"],
      main: "readme",
      source_url: "https://github.com/nsweeting/clickhouse",
      groups_for_modules: [
        # ClickHouse,
        # ClickHouse.Client,
        # ClickHouse.Query,
        # ClickHouse.Query.Sigils,
        # ClickHouse.Result,
        # ClickHouse.Stream,
        # ClickHouse.Telemetry,
        Formats: [
          ClickHouse.Format,
          ClickHouse.Format.JSONCompactEachRow,
          ClickHouse.Format.RowBinary,
          ClickHouse.Format.TSV,
          ClickHouse.Format.TSVWithNames,
          ClickHouse.Format.TSVWithNamesAndTypes,
          ClickHouse.Format.Values
        ],
        Interfaces: [
          ClickHouse.Interface,
          ClickHouse.Interface.HTTP
        ],
        DataTypes: [
          ClickHouse.DataType,
          ClickHouse.DataType.Encodable
        ],
        Errors: [
          ClickHouse.ConnectionError,
          ClickHouse.CoordinationError,
          ClickHouse.DatabaseError,
          ClickHouse.ParsingError,
          ClickHouse.QueryError,
          ClickHouse.StreamError,
          ClickHouse.SystemError
        ]
      ]
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  defp aliases do
    [
      setup: [
        "local.hex --if-missing --force",
        "local.rebar --if-missing --force",
        "deps.get"
      ],
      ci: [
        "deps.get",
        "compile --warnings-as-errors",
        "format --check-formatted",
        "credo --strict",
        "test"
      ]
    ]
  end

  # Specifies the preferred env for mix commands.
  defp preferred_cli_env do
    [
      ci: :test
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:benchee, "~> 1.0", only: :dev},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false},
      {:hackney, "~> 1.17"},
      {:jason, "~> 1.2", optional: true},
      {:keyword_validator, "~> 2.0"},
      {:nimble_csv, "~> 1.1", optional: true},
      {:telemetry, "~> 0.4 or ~> 1.0", optional: true}
    ]
  end
end
