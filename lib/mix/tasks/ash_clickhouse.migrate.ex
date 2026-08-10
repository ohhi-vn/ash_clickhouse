defmodule Mix.Tasks.AshClickhouse.Migrate do
  @moduledoc """
  Creates ClickHouse tables for all AshClickhouse resources.

      mix ash_clickhouse.migrate

  This is equivalent to running `mix ash.migrate` and delegates to
  `AshClickhouse.DataLayer.Extension.migrate/1`.
  """

  use Mix.Task

  alias AshClickhouse.DataLayer.Extension

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("compile")
    Extension.migrate(args)
  end
end
