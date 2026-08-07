defmodule Mix.Tasks.AshClickhouse.Setup do
  @moduledoc """
  Creates the ClickHouse database for the configured repo.

      mix ash_clickhouse.setup
  """

  use Mix.Task

  alias Mix.Tasks.AshClickhouse.Helpers

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("compile")
    repos = Helpers.find_repos()

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
end
