defmodule AshClickhouse.Schema do
  @moduledoc """
  Contract implemented by generated ClickHouse migration modules.
  """

  @callback repo() :: module()
  @callback change() :: [String.t()]
  @callback version() :: String.t()
  @callback down() :: [String.t()]

  @optional_callbacks version: 0, down: 0

  defmacro __using__(_opts) do
    quote do
      @behaviour AshClickhouse.Schema
    end
  end
end
