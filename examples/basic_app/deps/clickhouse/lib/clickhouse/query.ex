defmodule ClickHouse.Query do
  @moduledoc """
  A ClickHouse query.
  """

  alias ClickHouse.{DataType, Query.Statement}

  defstruct [
    :format,
    :statement
  ]

  @typedoc """
  A ClickHouse query
  """
  @type t :: %__MODULE__{
          format: ClickHouse.Format.t() | nil,
          statement: iolist()
        }

  ################################
  # Public API
  ################################

  @doc """
  Prepares a new ClickHouse query.
  """
  @spec prepare(
          ClickHouse.Client.t(),
          ClickHouse.statement(),
          ClickHouse.params()
        ) ::
          ClickHouse.Query.t()
  def prepare(client, statement, params \\ [])

  def prepare(client, statement, params) when is_binary(statement) do
    statement = Statement.new(statement)
    prepare(client, statement, params)
  end

  def prepare(client, %Statement{} = statement, params) do
    format = Map.get(client.formats, statement.format)
    {types, params} = _params(params)
    statement = encode(format, statement, types, params)
    %__MODULE__{format: format, statement: statement}
  end

  ################################
  # Private API
  ################################

  defp encode(_, %Statement{command: :insert, tokens: tokens}, _, []) do
    tokens
  end

  defp encode(nil, %Statement{command: :insert}, _, [_ | _]) do
    raise ClickHouse.QueryError, """
    Insert statements with row params must be provided a valid format.

    Please see ClickHouse.Format documentation for more information.
    """
  end

  defp encode(format, %Statement{command: :insert, tokens: tokens}, types, rows) do
    params = format.encode(types, rows)
    [tokens, "\n", params]
  end

  defp encode(_, %Statement{command: command} = statement, _, params)
       when command in [:insert_select, :select, :create, :alter, :unknown] do
    do_encode(statement.tokens, params)
  end

  defp do_encode(parts, params, acc \\ [])

  defp do_encode([], _, acc), do: acc

  defp do_encode(["?" | _], [], _acc) do
    raise ClickHouse.QueryError, """
    Query parameters do not match the number of embedded '?' in the query statement.
    """
  end

  defp do_encode(["?"], [data], acc) do
    [acc | [DataType.encode(data)]]
  end

  defp do_encode(["?" | parts], [data | params], acc) do
    do_encode(parts, params, [acc | [DataType.encode(data)]])
  end

  defp do_encode([part], _params, acc) do
    [acc | [part]]
  end

  defp do_encode([part | parts], params, acc) do
    do_encode(parts, params, [acc | [part]])
  end

  defp _params(params) when is_list(params), do: {[], params}
  defp _params({types, params}), do: {types, params}

  defimpl String.Chars do
    def to_string(%{statement: statement}) do
      IO.iodata_to_binary(statement)
    end
  end

  defimpl Inspect do
    def inspect(%{statement: statement}, _) do
      "#ClickHouse.Query<\"#{IO.iodata_to_binary(statement)}\">"
    end
  end
end
