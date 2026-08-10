defmodule Mix.Tasks.AshClickhouse.Helpers do
  @moduledoc """
  Shared helpers for the `ash_clickhouse` mix tasks.

  Both `mix ash_clickhouse.setup` and `mix ash_clickhouse.migrate` need to
  enumerate the app's compiled modules to find AshClickhouse repos and
  resources. Centralising this keeps the two tasks consistent and avoids
  duplicated discovery logic.
  """

  @doc """
  Returns the configured `Mix.Project.config()[:app]` name, or `nil` if none.
  """
  @spec app_name() :: atom() | nil
  def app_name do
    Mix.Project.config()[:app]
  end

  @doc """
  Returns every module compiled into the app that declares
  `__ash_clickhouse_repo__/0` (i.e. AshClickhouse repos).
  """
  @spec find_repos() :: [module()]
  def find_repos do
    modules()
    |> Enum.filter(fn mod ->
      Code.ensure_loaded?(mod) && function_exported?(mod, :__ash_clickhouse_repo__, 0)
    end)
  end

  @doc """
  Returns every module compiled into the app that declares
  `__ash_clickhouse__/1` (i.e. AshClickhouse resources).
  """
  @spec find_resources() :: [module()]
  def find_resources do
    modules()
    |> Enum.filter(fn mod ->
      Code.ensure_loaded?(mod) && function_exported?(mod, :__ash_clickhouse__, 1)
    end)
  end

  @doc """
  Starts the ClickHouse connection for each repo.

  Mix tasks (`mix ash_clickhouse.setup`, `mix ash_clickhouse.migrate`) run
  queries through the repos, so the client must be registered even when the
  application itself is not started.
  """
  @spec start_clients([module()], keyword()) :: :ok
  def start_clients(repos, overrides \\ []) do
    ensure_http_client_started()

    Enum.each(repos, fn repo ->
      opts = Keyword.merge(AshClickhouse.Repo.config_to_conn_opts(repo), overrides)

      case AshClickhouse.Connection.start_link(opts) do
        {:ok, _pid} ->
          :ok

        {:error, reason} ->
          Mix.raise(
            "Failed to start ClickHouse connection for #{inspect(repo)}: #{inspect(reason)}"
          )
      end
    end)

    :ok
  end

  # The `clickhouse` client talks to ClickHouse over HTTP via hackney. In mix
  # tasks the application is not started, so hackney's `:hackney_pool` ETS table
  # would be missing and the HTTP interface would fail to start. Ensure hackney
  # (and its dependencies) are running before opening connections.
  defp ensure_http_client_started do
    case Application.ensure_all_started(:hackney) do
      {:ok, _apps} ->
        :ok

      {:error, reason} ->
        Mix.raise("Failed to start :hackney: #{inspect(reason)}")
    end
  end

  defp modules do
    case app_name() do
      nil ->
        []

      app ->
        Application.load(app)
        Application.spec(app, :modules) || []
    end
  rescue
    _ -> []
  end
end
