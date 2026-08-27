defmodule AshClickhouse.Application do
  @moduledoc false

  use Application

  @repo_cache :ash_clickhouse_repo_cache
  @metadata_cache :ash_clickhouse_resource_metadata

  @impl Application
  def start(_type, _args) do
    # Create shared caches at boot. Their owner must be a long-lived
    # application process rather than an arbitrary request process, otherwise
    # ETS deletes the tables when the first request exits.
    ensure_cache(@repo_cache)
    ensure_cache(@metadata_cache)

    children = []

    opts = [strategy: :one_for_one, name: AshClickhouse.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp ensure_cache(table) do
    case :ets.whereis(table) do
      :undefined ->
        :ets.new(table, [:named_table, :public, {:read_concurrency, true}])

      _ ->
        :ok
    end
  end
end
