defprotocol ClickHouse.DataType.Encodable do
  @moduledoc """
  A protocol to encode Elixir data types into ClickHouse data types.
  """

  @spec encode(any()) :: iodata()
  def encode(data)
end

defimpl ClickHouse.DataType.Encodable, for: Atom do
  @moduledoc false

  import ClickHouse.Utils, only: [escape: 1]

  @spec encode(atom()) :: iodata()
  def encode(false), do: "0"
  def encode(true), do: "1"
  def encode(nil), do: "NULL"

  def encode(atom) do
    ["'", atom |> to_string() |> escape(), "'"]
  end
end

defimpl ClickHouse.DataType.Encodable, for: Date do
  @moduledoc false

  @spec encode(Date.t()) :: iodata()
  def encode(date) do
    ["'", to_string(date), "'"]
  end
end

defimpl ClickHouse.DataType.Encodable, for: DateTime do
  @moduledoc false

  @spec encode(DateTime.t()) :: iodata()
  def encode(datetime) do
    datetime =
      datetime
      |> DateTime.truncate(:second)
      |> DateTime.to_iso8601()
      |> String.replace("Z", "")

    ["'", datetime, "'"]
  end
end

defimpl ClickHouse.DataType.Encodable, for: Float do
  @moduledoc false

  @spec encode(float()) :: iodata()
  def encode(float), do: to_string(float)
end

defimpl ClickHouse.DataType.Encodable, for: Integer do
  @moduledoc false

  @spec encode(integer()) :: iodata()
  def encode(integer), do: to_string(integer)
end

defimpl ClickHouse.DataType.Encodable, for: List do
  @moduledoc false

  import ClickHouse.Utils, only: [intersperse_map: 3]

  alias ClickHouse.DataType

  @spec encode(list()) :: iodata()
  def encode(list) do
    ["[", intersperse_map(list, ",", &DataType.encode/1), "]"]
  end
end

defimpl ClickHouse.DataType.Encodable, for: BitString do
  @moduledoc false

  import ClickHouse.Utils, only: [escape: 1]

  @spec encode(binary()) :: iodata()
  def encode(string) do
    ["'", escape(string), "'"]
  end
end

defimpl ClickHouse.DataType.Encodable, for: Tuple do
  @moduledoc false

  import ClickHouse.Utils, only: [intersperse_map: 3]

  alias ClickHouse.DataType

  @spec encode(tuple()) :: iodata()
  def encode(tuple) do
    list = Tuple.to_list(tuple)
    ["tuple(", intersperse_map(list, ",", &DataType.encode/1), ")"]
  end
end
