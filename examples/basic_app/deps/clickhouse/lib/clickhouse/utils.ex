defmodule ClickHouse.Utils do
  @moduledoc false

  ################################
  # Public API
  ################################

  @spec intersperse_map(list, any, any, any) :: any
  def intersperse_map(list, seperator, mapper, acc \\ [])

  def intersperse_map([], _separator, _mapper, acc), do: acc

  def intersperse_map([elem], _separator, mapper, acc) do
    [acc | mapper.(elem)]
  end

  def intersperse_map([elem | rest], separator, mapper, acc) do
    intersperse_map(rest, separator, mapper, [acc, mapper.(elem), separator])
  end

  @spec escape(bitstring) :: iodata()
  def escape(string) do
    escape(string, 0, string, [])
  end

  ################################
  # Private API
  ################################

  escapes = [?', ?", 92]

  for match <- escapes do
    defp escape(<<unquote(match), rest::bits>>, skip, original, acc) do
      escape(rest, skip + 1, original, [acc, 92, unquote(match)])
    end
  end

  defp escape(<<_char, rest::bits>>, skip, original, acc) do
    escape(rest, skip, original, acc, 1)
  end

  defp escape(<<>>, _skip, _original, acc) do
    acc
  end

  for match <- escapes do
    defp escape(<<unquote(match), rest::bits>>, skip, original, acc, len) do
      part = binary_part(original, skip, len)
      escape(rest, skip + len + 1, original, [acc, part, 92, unquote(match)])
    end
  end

  defp escape(<<_char, rest::bits>>, skip, original, acc, len) do
    escape(rest, skip, original, acc, len + 1)
  end

  defp escape(<<>>, 0, original, _acc, _len) do
    original
  end

  defp escape(<<>>, skip, original, acc, len) do
    [acc, binary_part(original, skip, len)]
  end
end
