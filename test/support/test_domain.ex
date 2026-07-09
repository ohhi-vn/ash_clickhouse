defmodule AshClickhouse.TestDomain do
  @moduledoc "Test Ash domain for integration tests."
  use Ash.Domain

  resources do
    resource(AshClickhouse.TestResource)
  end
end
