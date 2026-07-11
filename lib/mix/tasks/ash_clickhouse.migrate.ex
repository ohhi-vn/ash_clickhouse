defmodule Mix.Tasks.AshClickhouse.Migrate do
  @moduledoc """
  Creates ClickHouse tables for all AshClickhouse resources.

      mix ash_clickhouse.migrate
  """

  use Mix.Task

  alias AshClickhouse.DataLayer.Dsl
  alias AshClickhouse.Migration

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("compile")
    repos = find_repos()

    Enum.each(repos, fn repo ->
      resources = find_resources()

      Enum.each(resources, fn resource ->
        resource_repo = Dsl.repo(resource)

        if is_nil(resource_repo) or resource_repo == repo do
          if Dsl.migrate?(resource) do
            create_statements = Migration.generate_resource_cql(resource)
            run_statements(repo, create_statements, "Migrated", resource)

            alter_statements = Migration.alter_table_cql(resource, repo)
            run_statements(repo, alter_statements, "Altered", resource)

            {index_statements, index_warnings} = Migration.alter_indexes_cql(resource, repo)
            run_statements(repo, index_statements, "Added index for", resource)

            Enum.each(index_warnings, fn warning ->
              Mix.shell().error(warning)
            end)
          end
        end
      end)
    end)
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

  defp find_repos do
    app = Mix.Project.config()[:app]
    modules = Application.spec(app, :modules) || []
    Enum.filter(modules, fn mod -> function_exported?(mod, :__ash_clickhouse_repo__, 0) end)
  rescue
    _ -> []
  end

  defp find_resources do
    app = Mix.Project.config()[:app]
    modules = Application.spec(app, :modules) || []
    Enum.filter(modules, fn mod -> function_exported?(mod, :__ash_clickhouse__, 1) end)
  rescue
    _ -> []
  end
end
