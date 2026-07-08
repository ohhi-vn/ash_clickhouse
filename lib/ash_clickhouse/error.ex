defmodule AshClickhouse.Error do
  @moduledoc """
  Error types for the AshClickhouse data layer.

  Errors raised or returned by the data layer are wrapped in one of these
  structs so that Ash can present consistent, structured error messages.
  """

  defmodule ClickhouseError do
    @moduledoc "An error returned by the ClickHouse client."
    defexception [:message, :query, :params, :reason]

    def from_error(%__MODULE__{} = error), do: error

    def from_error(%{message: message} = reason) do
      %__MODULE__{message: to_string(message), reason: reason}
    end

    def from_error(reason) do
      %__MODULE__{message: inspect(reason), reason: reason}
    end

    @impl true
    def exception(value) when is_binary(value) do
      %__MODULE__{message: value}
    end

    def exception(opts) when is_list(opts) do
      struct!(__MODULE__, opts)
    end

    def exception(reason) do
      from_error(reason)
    end
  end

  defmodule QueryError do
    @moduledoc "An error while building or running a query."
    defexception [:message, :query, :params]

    def from_error(message) when is_binary(message), do: %__MODULE__{message: message}

    def from_error(%__MODULE__{} = error), do: error

    def from_error(reason), do: %__MODULE__{message: inspect(reason)}
  end

  defmodule ConfigurationError do
    @moduledoc "An error in data layer or repo configuration."
    defexception [:message]

    def exception(value) when is_binary(value), do: %__MODULE__{message: value}
    def exception(opts) when is_list(opts), do: struct!(__MODULE__, opts)
  end

  @doc """
  Wraps a ClickHouse client error into an Ash-compatible error.
  """
  @spec wrap_clickhouse_error(term()) :: AshClickhouse.Error.ClickhouseError.t()
  def wrap_clickhouse_error(error) do
    ClickhouseError.from_error(error)
  end
end
