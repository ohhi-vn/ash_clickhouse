defmodule AshClickhouse.MigrationRunner do
  @moduledoc "Runs generated ClickHouse migration files for a repo."

  @spec run(module(), keyword()) :: :ok
  def run(repo, opts \\ []) do
    migration_path = Keyword.get(opts, :migration_path, "priv/repo/migrations")

    migration_path
    |> Path.join("*.exs")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.flat_map(&Code.require_file/1)
    |> Enum.map(&elem(&1, 0))
    |> Enum.filter(fn module ->
      function_exported?(module, :repo, 0) and module.repo() == repo and
        function_exported?(module, :change, 0)
    end)
    |> Enum.each(fn module ->
      Enum.each(module.change(), fn statement ->
        case repo.query(statement, []) do
          {:ok, _} ->
            Mix.shell().info("Applied #{inspect(module)}")

          {:error, reason} ->
            Mix.raise("Failed to apply #{inspect(module)}: #{inspect(reason)}")
        end
      end)
    end)

    :ok
  end
end
