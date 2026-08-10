defmodule AshClickhouse.DataLayer.Extension do
  @moduledoc """
  Integration point that exposes `ash_clickhouse` to the standard Ash mix tasks.

  `mix ash.codegen` and `mix ash.migrate` scan the application for modules that
  implement `Spark.Dsl.Extension` and invoke `codegen/1` and `migrate/1` on each
  of them. This module fills that role for ClickHouse:

  * `codegen/1` prints the `CREATE TABLE` / `ALTER TABLE` statements that Ash
    would run for every resource with a working `migrate?` flag, without
    touching the database.
  * `migrate/1` runs those statements against every configured repo, matching
    the behaviour of `mix ash_clickhouse.migrate`.

  The ClickHouse DSL is a lightweight macro layer (see
  `AshClickhouse.DataLayer.Dsl.Macros`) rather than a full Spark DSL section, so
  this extension declares no sections of its own — it exists purely so that the
  Ash tasks discover and orchestrate the ClickHouse codegen/migrate pipeline.
  """

  @behaviour Ash.Extension

  use Spark.Dsl.Extension

  alias AshClickhouse.DataLayer.Dsl
  alias AshClickhouse.Migration
  alias AshClickhouse.MigrationGenerator
  alias AshClickhouse.MigrationRunner
  alias Mix.Tasks.AshClickhouse.Helpers

  @doc """
  The name shown by `mix ash.codegen` / `mix ash.migrate` for this extension.
  """
  def name, do: "AshClickhouse"

  @doc """
  Prints the DDL that `mix ash.migrate` would apply, without applying it.

  Accepts the `--dry-run` / `--check` flags forwarded by `mix ash.codegen`.
  Passing `--check` exits with a non-zero status when there is pending DDL, so
  it can be used in CI.
  """
  @spec codegen([String.t()]) :: :ok | no_return()
  def codegen(argv) do
    MigrationGenerator.generate(parse_codegen_argv(argv))
  end

  @doc false
  def parse_codegen_argv(argv) do
    [
      name: extract_name(argv),
      dev: "--dev" in argv,
      dry_run: "--dry-run" in argv,
      check: "--check" in argv
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == false end)
  end

  defp extract_name(argv) do
    case Enum.split_while(argv, &(&1 != "--name")) do
      {_, ["--name", name | _]} when is_binary(name) and name != "" ->
        name

      {[first | _], _} when is_binary(first) ->
        if String.starts_with?(first, "-"), do: nil, else: first

      _ ->
        nil
    end
  end

  @doc false
  def codegen(argv, resources) do
    {opts, _, _} =
      OptionParser.parse(argv,
        strict: [dry_run: :boolean, check: :boolean, name: :string]
      )

    statements = pending_statements(resources)

    Enum.each(statements, &IO.puts/1)

    if statements == [] do
      Mix.shell().info("No pending ClickHouse changes.")
    end

    if opts[:check] && statements != [] do
      Mix.raise("Pending ClickHouse changes. Run `mix ash.codegen --dry-run` to review.")
    end

    :ok
  end

  @doc """
  Applies the pending ClickHouse changes for all configured resources.
  """
  @spec migrate([String.t()]) :: :ok
  def migrate(_argv) do
    Mix.Task.run("compile")
    repos = Helpers.find_repos()
    Helpers.start_clients(repos)

    Enum.each(repos, &MigrationRunner.run/1)
  end

  @doc false
  def migrate(repos, resources) do
    Enum.each(resources, fn resource ->
      repo = Dsl.repo(resource)

      cond do
        is_nil(repo) ->
          Mix.shell().error(
            "Skipping #{inspect(resource)}: no repo configured (add `repo MyApp.Repo` to its clickhouse block)."
          )

        Enum.member?(repos, repo) ->
          migrate_resource(repo, resource)

        true ->
          :ok
      end
    end)

    :ok
  end

  @doc false
  def pending_statements(resources) do
    resources
    |> Enum.filter(&Dsl.migrate?/1)
    |> Enum.flat_map(fn resource ->
      case Dsl.repo(resource) do
        nil ->
          Mix.shell().error(
            "Skipping #{inspect(resource)}: no repo configured (add `repo MyApp.Repo` to its clickhouse block)."
          )

          []

        repo ->
          create = Migration.create_table_cql(resource)

          if Migration.table_exists?(resource, repo) do
            alter = Migration.alter_table_cql(resource, repo)
            {index, _} = Migration.alter_indexes_cql(resource, repo)
            alter ++ index
          else
            [create]
          end
      end
    end)
  end

  defp migrate_resource(repo, resource) do
    if Dsl.migrate?(resource) do
      try do
        create_statements = Migration.generate_resource_cql(resource)
        run_statements(repo, create_statements, "Migrated", resource)

        alter_statements = Migration.alter_table_cql(resource, repo)
        run_statements(repo, alter_statements, "Altered", resource)

        {index_statements, index_warnings} = Migration.alter_indexes_cql(resource, repo)
        run_statements(repo, index_statements, "Added index for", resource)

        Enum.each(index_warnings, fn warning ->
          Mix.shell().error(warning)
        end)
      rescue
        e ->
          Mix.shell().error(
            "Failed to generate migration for #{inspect(resource)}: #{Exception.message(e)}"
          )
      end
    end

    :ok
  end

  defp run_statements(repo, statements, verb, resource) do
    Enum.each(statements, fn statement ->
      case repo.query(statement, []) do
        {:ok, _} ->
          Mix.shell().info("#{verb} #{inspect(resource)}")

        {:error, reason} ->
          Mix.shell().error(
            "Failed to #{String.downcase(verb)} #{inspect(resource)}: #{inspect(reason)}"
          )
      end
    end)
  end
end
