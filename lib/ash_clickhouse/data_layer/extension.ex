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

  use Spark.Dsl.Extension

  alias AshClickhouse.DataLayer.Dsl
  alias AshClickhouse.Migration
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
    codegen(argv, Helpers.find_resources())
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

    Enum.each(repos, fn repo ->
      resources = Helpers.find_resources()

      Enum.each(resources, fn resource ->
        migrate_resource(repo, resource)
      end)
    end)

    :ok
  end

  @doc false
  def pending_statements(resources) do
    resources
    |> Enum.filter(&Dsl.migrate?/1)
    |> Enum.flat_map(fn resource ->
      create = Migration.create_table_cql(resource)
      alter = Migration.alter_table_cql(resource, repo_for(resource))
      {index, _} = Migration.alter_indexes_cql(resource, repo_for(resource))
      [create] ++ alter ++ index
    end)
  end

  defp repo_for(resource) do
    Dsl.repo(resource) ||
      raise(
        ArgumentError,
        "could not resolve a repo for #{inspect(resource)}; add `repo MyApp.Repo` to its clickhouse block"
      )
  end

  defp migrate_resource(repo, resource) do
    resource_repo = Dsl.repo(resource)

    cond do
      is_nil(resource_repo) ->
        Mix.shell().error(
          "Skipping #{inspect(resource)}: no repo configured (add `repo MyApp.Repo` to its clickhouse block)."
        )

      resource_repo == repo and Dsl.migrate?(resource) ->
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

      true ->
        :ok
    end
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
