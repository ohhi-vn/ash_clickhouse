defmodule AshClickhouse.Identifier do
  @moduledoc """
  Helpers for safely quoting and sanitizing ClickHouse identifiers.

  ClickHouse identifiers (table names, column names, database names) may be
  quoted with backticks. Unquoted identifiers are limited to a restricted set
  of characters. This module provides validation and quoting helpers so the
  data layer can build SQL safely without opening SQL-injection vectors.
  """

  @doc """
  Quotes an identifier with backticks, escaping any embedded backticks.

  ## Examples

      iex> AshClickhouse.Identifier.quote_name("users")
      "`users`"

      iex> AshClickhouse.Identifier.quote_name("my`table")
      "`my``table`"

  """
  @spec quote_name(String.t() | atom()) :: String.t()
  def quote_name(name) when is_atom(name), do: quote_name(to_string(name))

  def quote_name(name) when is_binary(name) do
    escaped = String.replace(name, "`", "``")
    "`#{escaped}`"
  end

  @doc """
  Sanitizes an identifier, raising `ArgumentError` if it is invalid.

  A valid ClickHouse identifier consists of letters, digits, and underscores,
  and must not start with a digit.
  """
  @spec sanitize!(String.t() | atom()) :: String.t()
  def sanitize!(name) when is_atom(name), do: sanitize!(to_string(name))

  def sanitize!(name) when is_binary(name) do
    if valid_identifier?(name) do
      name
    else
      raise ArgumentError,
            "Invalid ClickHouse identifier: #{inspect(name)}. " <>
              "Identifiers must match [a-zA-Z_][a-zA-Z0-9_]*."
    end
  end

  @doc """
  Returns true if the given identifier is a valid unquoted ClickHouse identifier.
  """
  @spec valid_identifier?(String.t() | atom()) :: boolean()
  def valid_identifier?(name) when is_atom(name), do: valid_identifier?(to_string(name))

  def valid_identifier?(name) when is_binary(name) do
    case String.first(name) do
      nil -> false
      <<first::utf8>> -> first in ?a..?z or first in ?A..?Z or first == ?_
      _ -> false
    end and
      String.match?(name, ~r/^[a-zA-Z_][a-zA-Z0-9_]*$/)
  end

  @doc """
  Validates a database name, raising `ArgumentError` if invalid.
  """
  @spec validate_database!(String.t() | nil) :: :ok
  def validate_database!(nil), do: :ok

  def validate_database!(database) when is_binary(database) do
    if valid_identifier?(database) do
      :ok
    else
      raise ArgumentError, "Invalid ClickHouse database name: #{inspect(database)}"
    end
  end

  @doc """
  Validates a table name, raising `ArgumentError` if invalid.
  """
  @spec validate_table!(String.t()) :: :ok
  def validate_table!(table) when is_binary(table) do
    if valid_identifier?(table) do
      :ok
    else
      raise ArgumentError, "Invalid ClickHouse table name: #{inspect(table)}"
    end
  end
end
