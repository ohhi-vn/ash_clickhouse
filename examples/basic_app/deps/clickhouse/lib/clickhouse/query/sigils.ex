defmodule ClickHouse.Query.Sigils do
  @moduledoc """
  Sigils for preparing ClickHouse queries.
  """

  alias ClickHouse.Query.Statement

  defmacro sigil_q(term, modifiers)

  defmacro sigil_q({:<<>>, _, [string]}, _modifiers) when is_binary(string) do
    quote(do: Statement.new(unquote(string)))
  end

  defmacro sigil_q({:<<>>, meta, pieces}, _modifiers) do
    tokens = unescape_tokens(pieces)
    binary = {:<<>>, meta, tokens}
    quote(do: Statement.new(unquote(binary)))
  end

  defmacro sigil_Q(term, modifiers)

  defmacro sigil_Q({:<<>>, _, [string]}, _modifiers) when is_binary(string) do
    quote(do: Statement.new(unquote(string)))
  end

  defp unescape_tokens(tokens) do
    case :elixir_interpolation.unescape_tokens(tokens) do
      {:ok, unescaped_tokens} -> unescaped_tokens
      {:error, reason, _} -> raise ArgumentError, to_string(reason)
    end
  end
end
