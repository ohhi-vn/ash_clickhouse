defmodule ClickHouse.Format.RowBinary do
  @moduledoc """
  An implementation of the ClickHouse `RowBinary` format.
  """

  @behaviour ClickHouse.Format

  import Bitwise

  @dialyzer {:no_improper_lists, {:encode_size, 1}}

  @epoch_date ~D[1970-01-01]
  @epoch_naive_datetime ~N[1970-01-01 00:00:00]
  @epoch_utc_datetime ~U[1970-01-01 00:00:00Z]

  ################################
  # ClickHouse.Format Callbacks
  ################################

  @impl ClickHouse.Format
  @spec names() :: [binary()]
  def names, do: ["RowBinary"]

  @impl ClickHouse.Format
  @spec decode(raw :: iodata()) :: no_return()
  def decode(_raw) do
    raise ClickHouse.QueryError, """
    RowBinary decode not implemented.
    """
  end

  @impl ClickHouse.Format
  @spec encode(ClickHouse.data_types(), rows :: list()) :: iodata()
  def encode(types, [row | rows]), do: encode_row(types, row, types, rows)
  def encode(_, [] = done), do: done

  ################################
  # Private API
  ################################

  defp encode_row([], [_ | _], _, _) do
    raise ClickHouse.QueryError, """
    RowBinary format must be given data types.
    """
  end

  defp encode_row([t | ts], [v | vs], types, rows) do
    [encode_value(t, v) | encode_row(ts, vs, types, rows)]
  end

  defp encode_row([], [], types, rows) do
    encode(types, rows)
  end

  # String

  defp encode_value(:string, v) when is_binary(v) do
    bytes = byte_size(v)
    [encode_size(bytes) | v]
  end

  defp encode_value(:string, v) when is_list(v) do
    bytes = IO.iodata_length(v)
    [encode_size(bytes) | v]
  end

  defp encode_value(:string, v) when is_atom(v), do: encode_value(:string, to_string(v))
  defp encode_value(:string, nil), do: 0

  # Array

  defp encode_value({:array, _}, []), do: 0
  defp encode_value({:array, _}, nil), do: 0

  defp encode_value({:array, t}, v) when is_list(v) do
    [encode_size(length(v)) | encode_many(t, v)]
  end

  # Tuple

  defp encode_value({:tuple, _}, _) do
    raise ClickHouse.QueryError, """
    RowBinary encode not implemented for tuples.
    """
  end

  # Boolean

  defp encode_value(:boolean, true), do: 1
  defp encode_value(:boolean, false), do: 0
  defp encode_value(:boolean, 0), do: 0
  defp encode_value(:boolean, 1), do: 1
  defp encode_value(:boolean, nil), do: 0

  # Integer

  defp encode_value(:i64, v) when is_integer(v), do: <<v::64-little-signed>>
  defp encode_value(:i64, nil), do: <<0::64>>
  defp encode_value(:i32, v) when is_integer(v), do: <<v::32-little-signed>>
  defp encode_value(:i32, nil), do: <<0::32>>
  defp encode_value(:i16, v) when is_integer(v), do: <<v::16-little-signed>>
  defp encode_value(:i16, nil), do: <<0::16>>
  defp encode_value(:i8, v) when is_integer(v) and v >= 0, do: v
  defp encode_value(:i8, v) when is_integer(v), do: <<v::signed>>
  defp encode_value(:i8, nil), do: <<0::8>>

  # Unsigned Integer

  defp encode_value(:u64, v) when is_integer(v), do: <<v::64-little>>
  defp encode_value(:u64, nil), do: <<0::64>>
  defp encode_value(:u32, v) when is_integer(v), do: <<v::32-little>>
  defp encode_value(:u32, nil), do: <<0::32>>
  defp encode_value(:u16, v) when is_integer(v), do: <<v::16-little>>
  defp encode_value(:u16, nil), do: <<0::16>>
  defp encode_value(:u8, v) when is_integer(v), do: <<v::8-little>>
  defp encode_value(:u8, nil), do: <<0::8>>

  # Float

  defp encode_value(:f64, v) when is_number(v), do: <<v::64-little-signed-float>>
  defp encode_value(:f64, nil), do: <<0::64>>
  defp encode_value(:f32, v) when is_number(v), do: <<v::32-little-signed-float>>
  defp encode_value(:f32, nil), do: <<0::32>>

  # Date

  defp encode_value(:date, %Date{} = v), do: <<Date.diff(v, @epoch_date)::16-little>>
  defp encode_value(:date, v) when is_binary(v), do: encode_value(:date, Date.from_iso8601!(v))
  defp encode_value(:date, nil), do: <<0::16>>

  # Date32

  defp encode_value(:date32, %Date{} = v), do: <<Date.diff(v, @epoch_date)::32-little>>

  defp encode_value(:date32, v) when is_binary(v),
    do: encode_value(:date32, Date.from_iso8601!(v))

  defp encode_value(:date32, nil), do: <<0::32>>

  # DateTime

  defp encode_value(:datetime, %NaiveDateTime{} = v),
    do: <<NaiveDateTime.diff(v, @epoch_naive_datetime)::32-little>>

  defp encode_value(:datetime, %DateTime{time_zone: "Etc/UTC"} = v) do
    <<DateTime.to_unix(v, :second)::32-little>>
  end

  defp encode_value(:datetime, %DateTime{} = v) do
    raise ClickHouse.QueryError, """
    RowBinary format does not support non-UTC timezones when encoding DateTimes's.

    The following datetime was given: #{v}
    """
  end

  defp encode_value(:datetime, v) when is_integer(v), do: <<v::32-little>>
  defp encode_value(:datetime, nil), do: <<0::32>>

  # DateTime64

  defp encode_value({:datetime64, p}, %NaiveDateTime{} = v) do
    <<NaiveDateTime.diff(v, @epoch_naive_datetime, p)::64-little-signed>>
  end

  defp encode_value({:datetime64, p}, %DateTime{time_zone: "Etc/UTC"} = v) do
    <<DateTime.diff(v, @epoch_utc_datetime, p)::64-little-signed>>
  end

  defp encode_value({:datetime64, _}, %DateTime{} = v) do
    raise ClickHouse.QueryError, """
    RowBinary format does not support non-UTC timezones when encoding DateTimes's.

    The following datetime was given: #{v}
    """
  end

  defp encode_value({:datetime64, _}, nil), do: <<0::64>>

  # Nullable

  defp encode_value({:nullable, _}, nil), do: 1

  defp encode_value({:nullable, t}, v) do
    case encode_value(t, v) do
      e when is_list(e) or is_binary(e) -> [0 | e]
      e -> [0, e]
    end
  end

  # Enum

  defp encode_value({:enum8, _}, v) when is_integer(v), do: encode_value(:i8, v)
  defp encode_value({:enum8, _}, nil), do: <<0::8>>

  defp encode_value({:enum8, m}, v) when is_binary(v) or is_atom(v) do
    case Map.fetch(m, v) do
      {:ok, v} -> encode_value(:i8, v)
      :error -> invalid_enum(:enum8, m, v)
    end
  end

  defp encode_value({:enum16, _}, v) when is_integer(v), do: encode_value(:i16, v)
  defp encode_value({:enum16, _}, nil), do: <<0::16>>

  defp encode_value({:enum16, m}, v) when is_binary(v) or is_atom(v) do
    case Map.fetch(m, v) do
      {:ok, v} -> encode_value(:i16, v)
      :error -> invalid_enum(:enum16, m, v)
    end
  end

  # UUID

  defp encode_value(:uuid, <<v1::64, v2::64>>), do: <<v1::64-little, v2::64-little>>
  defp encode_value(:uuid, nil), do: <<0::128>>
  defp encode_value(:uuid, ""), do: <<0::128>>

  defp encode_value(
         :uuid,
         <<a1, a2, a3, a4, a5, a6, a7, a8, ?-, b1, b2, b3, b4, ?-, c1, c2, c3, c4, ?-, d1, d2, d3,
           d4, ?-, e1, e2, e3, e4, e5, e6, e7, e8, e9, e10, e11, e12>>
       ) do
    raw =
      <<d(a1)::4, d(a2)::4, d(a3)::4, d(a4)::4, d(a5)::4, d(a6)::4, d(a7)::4, d(a8)::4, d(b1)::4,
        d(b2)::4, d(b3)::4, d(b4)::4, d(c1)::4, d(c2)::4, d(c3)::4, d(c4)::4, d(d1)::4, d(d2)::4,
        d(d3)::4, d(d4)::4, d(e1)::4, d(e2)::4, d(e3)::4, d(e4)::4, d(e5)::4, d(e6)::4, d(e7)::4,
        d(e8)::4, d(e9)::4, d(e10)::4, d(e11)::4, d(e12)::4>>

    encode_value(:uuid, raw)
  end

  # Low Cardinality

  defp encode_value({:low_cardinality, t}, v), do: encode_value(t, v)

  # Fixed String

  defp encode_value({:fixed_string, s}, v) when byte_size(v) == s, do: v
  defp encode_value({:fixed_string, s}, nil), do: <<0::size(s * 8)>>

  defp encode_value({:fixed_string, s}, v) when byte_size(v) < s do
    to_pad = s - byte_size(v)
    [v | <<0::size(to_pad * 8)>>]
  end

  defp encode_size(size) when size < 128, do: <<size>>

  defp encode_size(size) do
    [(size &&& 0b0111_1111) ||| 0b1000_0000 | encode_size(size >>> 7)]
  end

  defp encode_many(type, [value | list]) do
    [encode_value(type, value) | encode_many(type, list)]
  end

  defp encode_many(_type, [] = done), do: done

  @compile {:inline, d: 1}

  defp d(?0), do: 0
  defp d(?1), do: 1
  defp d(?2), do: 2
  defp d(?3), do: 3
  defp d(?4), do: 4
  defp d(?5), do: 5
  defp d(?6), do: 6
  defp d(?7), do: 7
  defp d(?8), do: 8
  defp d(?9), do: 9
  defp d(?A), do: 10
  defp d(?B), do: 11
  defp d(?C), do: 12
  defp d(?D), do: 13
  defp d(?E), do: 14
  defp d(?F), do: 15
  defp d(?a), do: 10
  defp d(?b), do: 11
  defp d(?c), do: 12
  defp d(?d), do: 13
  defp d(?e), do: 14
  defp d(?f), do: 15

  @compile {:inline, invalid_enum: 3}

  defp invalid_enum(type, mapping, value) do
    raise ClickHouse.QueryError, """
    Invalid #{type} mapping or value provided for RowBinary encode.

    Please ensure the value is included in the mapping.

    Mapping: #{inspect(mapping)}
    Value: #{inspect(value)}
    """
  end
end
