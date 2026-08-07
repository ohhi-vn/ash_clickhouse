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
    |> Enum.filter(fn mod -> function_exported?(mod, :__ash_clickhouse_repo__, 0) end)
  end

  @doc """
  Returns every module compiled into the app that declares
  `__ash_clickhouse__/1` (i.e. AshClickhouse resources).
  """
  @spec find_resources() :: [module()]
  def find_resources do
    modules()
    |> Enum.filter(fn mod -> function_exported?(mod, :__ash_clickhouse__, 1) end)
  end

  defp modules do
    case app_name() do
      nil -> []
      app -> Application.spec(app, :modules) || []
    end
  rescue
    _ -> []
  end
end
