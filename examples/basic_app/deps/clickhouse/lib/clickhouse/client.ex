defmodule ClickHouse.Client do
  @moduledoc """
  A ClickHouse client.
  """

  defstruct [
    :name,
    :interface,
    :formats
  ]

  @type t :: %__MODULE__{
          name: atom(),
          interface: ClickHouse.Interface.t(),
          formats: %{ClickHouse.Format.name() => ClickHouse.Format.t()}
        }

  ################################
  # Public API
  ################################

  @doc """
  Creates a new ClickHouse client.
  """
  @spec new([ClickHouse.start_option()]) :: ClickHouse.Client.t()
  def new(opts) do
    name = Keyword.fetch!(opts, :name)
    interface = Keyword.fetch!(opts, :interface)
    formats = Keyword.fetch!(opts, :formats)
    formats = build_formats(formats)

    %__MODULE__{
      name: name,
      interface: interface,
      formats: formats
    }
  end

  ################################
  # Private API
  ################################

  defp build_formats(formats, acc \\ %{})

  defp build_formats([], acc), do: acc

  defp build_formats([format | formats], acc) do
    names =
      if Code.ensure_loaded?(format) do
        format.names()
      else
        []
      end

    acc = build_format(names, format, acc)
    build_formats(formats, acc)
  end

  defp build_format([], _, acc), do: acc

  defp build_format([name | names], format, acc) do
    acc = Map.put(acc, name, format)
    build_format(names, format, acc)
  end

  defimpl Inspect do
    def inspect(%{name: name}, _) do
      "#ClickHouse.Client<name: #{inspect(name)}>"
    end
  end
end
