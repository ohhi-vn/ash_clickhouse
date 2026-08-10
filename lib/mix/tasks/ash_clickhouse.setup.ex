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

    # Connect without a bound database: the target database may not exist yet
    # (that is what this task creates), so the CREATE DATABASE statement must
    # run against the server's default database.
    Helpers.start_clients(repos, database: nil)

    create_databases(repos)
  end

  @doc """
  Creates the database for each repo, printing the outcome to the shell.

  Split out from `run/1` so the success/error branches are unit-testable
  without the app's compiled modules.
  """
  @spec create_databases([module()]) :: :ok
  def create_databases(repos) do
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
