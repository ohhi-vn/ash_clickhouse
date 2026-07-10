defmodule ClickHouse.ConnectionError do
  @type t :: %__MODULE__{}

  defexception [:message]
end

defmodule ClickHouse.CoordinationError do
  @type t :: %__MODULE__{}

  defexception [:code, :message, :meta]
end

defmodule ClickHouse.DatabaseError do
  @type t :: %__MODULE__{}

  defexception [:code, :message, :meta]
end

defmodule ClickHouse.QueryError do
  @type t :: %__MODULE__{}

  defexception [:message]
end

defmodule ClickHouse.ParsingError do
  @type t :: %__MODULE__{}

  defexception [:code, :message, :meta]
end

defmodule ClickHouse.StreamError do
  @type t :: %__MODULE__{}

  defexception [:message]
end

defmodule ClickHouse.SystemError do
  @type t :: %__MODULE__{}

  defexception [:message]
end
