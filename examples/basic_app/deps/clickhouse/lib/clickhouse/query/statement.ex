defmodule ClickHouse.Query.Statement do
  @moduledoc false

  @values_regex ~r/values/i
  @format_regex ~r/(?<= (?:format) )(\w+)/i
  @insert_select_regex ~r/insert .*? select/i

  defstruct [
    :tokens,
    :command,
    :format
  ]

  @type command :: :create | :select | :insert | :insert_select | :alter | :unknown

  @type t :: %__MODULE__{
          tokens: iodata(),
          command: command(),
          format: ClickHouse.Format.name()
        }

  @spec new(binary()) :: ClickHouse.Query.Statement.t()
  def new(statement) do
    statement = strip_newlines_and_whitespace(statement)

    %__MODULE__{}
    |> put_command(statement)
    |> put_format(statement)
    |> put_tokens(statement)
  end

  ################################
  # Private API
  ################################

  defp strip_newlines_and_whitespace(raw) do
    raw
    |> String.replace("\n", " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim_leading()
    |> String.trim_trailing()
  end

  defp put_command(statement, raw) do
    command = parse_command(raw)
    %{statement | command: command}
  end

  defp parse_command("SELECT" <> _), do: :select
  defp parse_command("select" <> _), do: :select
  defp parse_command("CREATE" <> _), do: :create
  defp parse_command("create" <> _), do: :create
  defp parse_command("ALTER" <> _), do: :alter
  defp parse_command("alter" <> _), do: :alter
  defp parse_command("INSERT" <> _ = command), do: parse_insert(command)
  defp parse_command("insert" <> _ = command), do: parse_insert(command)
  defp parse_command(_), do: :unknown

  defp parse_insert(command) do
    if Regex.match?(@insert_select_regex, command) do
      :insert_select
    else
      :insert
    end
  end

  defp put_format(%{command: :insert} = statement, raw) do
    if Regex.match?(@values_regex, raw) do
      %{statement | format: "Values"}
    else
      %{statement | format: parse_format(raw)}
    end
  end

  defp put_format(statement, raw) do
    %{statement | format: parse_format(raw)}
  end

  defp parse_format(raw) do
    case Regex.run(@format_regex, raw, capture: :first) do
      [format] -> format
      _ -> nil
    end
  end

  defp put_tokens(%{command: :insert} = statement, raw) do
    raw =
      raw
      |> String.trim_trailing("?")
      |> String.trim_trailing()

    %{statement | tokens: raw}
  end

  defp put_tokens(statement, raw) do
    tokens = String.split(raw, "")
    %{statement | tokens: tokens}
  end

  defimpl String.Chars do
    def to_string(%{tokens: tokens}) do
      IO.iodata_to_binary(tokens)
    end
  end

  defimpl Inspect do
    def inspect(%{tokens: tokens}, _) do
      IO.iodata_to_binary(tokens)
    end
  end
end
