defmodule Mix.Tasks.AshClickhouse.Migrate do
  @moduledoc """
  Creates ClickHouse tables for all AshClickhouse resources.

      mix ash_clickhouse.migrate
  """

  use Mix.Task

  alias AshClickhouse.Migration

  @impl Mix.Task
  def run(_args) do
    repos = find_repos()

    Enum.each(repos, fn repo ->
      resources = find_resources()

      Enum.each(resources, fn resource ->
        if AshClickhouse.DataLayer.Dsl.migrate?(resource) do
          statements = Migration.generate_resource_cql(resource)

          Enum.each(statements, fn statement ->
            case repo.query(statement, []) do
              {:ok, _} ->
                Mix.shell().info("Migrated #{inspect(resource)}")

              {:error, reason} ->
                Mix.shell().error("Failed to migrate #{inspect(resource)}: #{inspect(reason)}")
            end
          end)
        end
      end)
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
