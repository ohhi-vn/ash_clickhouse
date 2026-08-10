defmodule AshClickhouse.Schema do
  @moduledoc """
  Contract implemented by generated ClickHouse migration modules.
  """

  @callback repo() :: module()
  @callback change() :: [String.t()]

  defmacro __using__(_opts) do
    quote do
      @behaviour AshClickhouse.Schema
    end
  end
end
