defmodule AshClickhouse.RecordTest do
  @moduledoc """
  Unit tests for AshClickhouse.DataLayer.Record row/record decoding.
  """
  use ExUnit.Case, async: true

  alias AshClickhouse.DataLayer.Record
  alias AshClickhouse.DataLayer.Types

  defmodule UuidAtomResource do
    use Ash.Resource,
      data_layer: AshClickhouse.DataLayer,
      domain: nil

    import AshClickhouse.DataLayer.Dsl.Macros

    clickhouse do
      table("record_decoding")
      repo(AshClickhouse.TestRepo)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string)
      attribute(:status, :atom)
    end
  end

  describe "to_ash_record/2 with a map row" do
    test "decodes a 16-byte binary UUID value back to its canonical string form" do
      uuid = "123e4567-e89b-12d3-a456-426614174000"
      {:ok, bin} = Types.uuid_string_to_binary(uuid)

      record = Record.to_ash_record(%{"id" => bin}, UuidAtomResource)
      assert record.id == uuid
    end

    test "leaves a non-16-byte UUID value untouched" do
      record = Record.to_ash_record(%{"id" => "not-a-uuid"}, UuidAtomResource)
      assert record.id == "not-a-uuid"
    end

    test "converts a binary value on an atom attribute to the existing atom" do
      _ = :active
      record = Record.to_ash_record(%{"status" => "active"}, UuidAtomResource)
      assert record.status == :active
    end
  end

  describe "to_existing_atom/1" do
    test "returns the existing atom for a known string" do
      _ = :ready
      assert Record.to_existing_atom("ready") == :ready
    end

    test "returns the string unchanged when no such atom exists" do
      assert Record.to_existing_atom("definitely_not_an_atom_xyz_987") ==
               "definitely_not_an_atom_xyz_987"
    end
  end
end
