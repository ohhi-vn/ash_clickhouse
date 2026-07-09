defmodule Mix.Tasks.AshClickhouse.Setup do
  @moduledoc """
  Creates the ClickHouse database for the configured repo.

      mix ash_clickhouse.setup
  """

  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("compile")
    repos = find_repos()

    if repos == [] do
      Mix.shell().info("No AshClickhouse.Repo modules found.")
      :ok
    else
      Enum.each(repos, fn repo ->
        case repo.create_database() do
          {:ok, _} -> Mix.shell().info("Created database for #{inspect(repo)}.")
          {:error, reason} -> Mix.shell().error("Failed: #{inspect(reason)}")
        end
      end)
    end
  end

  defp find_repos do
    modules = Mix.Project.config()[:app] && Application.spec(Mix.Project.config()[:app], :modules)
    modules = modules || []
    Enum.filter(modules, fn mod -> function_exported?(mod, :__ash_clickhouse_repo__, 0) end)
  rescue
    _ -> []
  end
end
