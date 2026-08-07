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

    def from_error(message) when is_binary(message) do
      %__MODULE__{message: message}
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

  # The exception structs raised/returned by the `clickhouse` client. These are
  # the only errors the data layer treats as client errors; anything else is a
  # genuine programming/runtime error and should propagate rather than being
  # silently swapped into a misleading "ClickHouse error".
  @client_error_modules [
    ClickHouse.QueryError,
    ClickHouse.ConnectionError,
    ClickHouse.DatabaseError,
    ClickHouse.ParsingError,
    ClickHouse.StreamError,
    ClickHouse.SystemError,
    ClickHouse.CoordinationError
  ]

  @doc """
  True when the given value is one of the `clickhouse` client's error structs.
  """
  @spec client_error?(term()) :: boolean()
  def client_error?(%mod{}) when mod in @client_error_modules, do: true
  def client_error?(_), do: false

  @doc """
  Wraps a ClickHouse client error into an Ash-compatible error.
  """
  @spec wrap_clickhouse_error(term()) :: AshClickhouse.Error.ClickhouseError.t()
  def wrap_clickhouse_error(error) do
    ClickhouseError.from_error(error)
  end

  @doc """
  Reraises a rescued exception, converting client errors to `ClickhouseError`.

  Client exceptions are translated to `AshClickhouse.Error.ClickhouseError` so
  callers get a consistent, structured error. Any *other* exception (a genuine
  bug in the library or caller) is reraised with its original stacktrace intact.
  """
  @spec reraise_or_wrap(term(), list()) :: no_return()
  def reraise_or_wrap(e, stacktrace) do
    if client_error?(e) do
      raise wrap_clickhouse_error(e)
    else
      reraise e, stacktrace
    end
  end
end
