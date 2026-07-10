defmodule AshClickhouse.Application do
  @moduledoc false

  use Application

  @impl Application
  def start(_type, _args) do
    # Create the repo-resolution cache once at boot so concurrent first-time
    # lookups can't race on `:ets.new` (which would otherwise crash one caller
    # with `ArgumentError: table already exists`). Guarded so a repeated start
    # (e.g. during code reload) does not crash.
    case :ets.whereis(:ash_clickhouse_repo_cache) do
      :undefined ->
        :ets.new(:ash_clickhouse_repo_cache, [:named_table, :public, {:read_concurrency, true}])

      _ ->
        :ok
    end

    children = []

    opts = [strategy: :one_for_one, name: AshClickhouse.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
