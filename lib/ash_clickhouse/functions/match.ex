defmodule AshClickhouse.Functions.Match do
  @moduledoc """
  ClickHouse's `match/2` — a regular expression match against a string.

  The function is published by the data layer (see
  `AshClickhouse.DataLayer.functions/1`), so it can be used in a filter:

      MyApp.User
      |> Ash.Query.filter(match(name, "^John"))
      |> Ash.read!()

  It is translated to ClickHouse's `match(haystack, pattern)` function.
  """
  use Ash.Query.Function, name: :match, predicate?: true

  @impl Ash.Query.Function
  def args, do: [[:string, :string]]

  @impl Ash.Query.Function
  def returns, do: [:boolean]

  @impl Ash.Query.Function
  def evaluate(%{arguments: [haystack, pattern]})
      when is_binary(haystack) and is_binary(pattern) do
    case Regex.compile(pattern) do
      {:ok, regex} -> {:known, Regex.match?(regex, haystack)}
      {:error, _reason} -> :unknown
    end
  end

  def evaluate(_other), do: :unknown
end
