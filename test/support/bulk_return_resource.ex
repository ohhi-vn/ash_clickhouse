defmodule AshClickhouse.BulkReturnRepo do
  @moduledoc """
  A stand-in repo for the bulk-return tests.

  `insert_rows/3` runs in the calling process, so it can hand the wire rows
  back to the test through the mailbox.
  """

  def insert_rows(_statement, rows, _opts) do
    send(self(), {:inserted, rows})
    {:ok, :ok}
  end

  def query(_sql, _params, _opts) do
    {:ok, %ClickHouse.Result{raw: "", meta: %{}, compressed: false, rows: [], columns: []}}
  end

  def query!(_sql, _params, _opts) do
    %ClickHouse.Result{raw: "", meta: %{}, compressed: false, rows: [], columns: []}
  end

  def database, do: "bulk_return_test"
end

defmodule AshClickhouse.BulkReturnResource do
  @moduledoc """
  A ClickHouse-backed Ash resource with temporal attributes and a column whose
  value ClickHouse computes itself, used by the bulk-return tests.
  """

  use Ash.Resource,
    data_layer: AshClickhouse.DataLayer,
    domain: AshClickhouse.BulkReturnDomain,
    validate_domain_inclusion?: false

  import AshClickhouse.DataLayer.Dsl.Macros

  clickhouse do
    table("bulk_return_users")
    repo(AshClickhouse.BulkReturnRepo)
    database("ash_clickhouse_test")
    engine("MergeTree()")
    order_by("id")
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:at, :utc_datetime_usec)
    attribute(:naive, :naive_datetime)
    attribute(:day, :date)
    attribute(:name, :string)
    # A column whose value ClickHouse computes itself: the resource declares
    # it and the create action never accepts it, so the submitted row carries
    # no value for it.
    attribute(:computed, :string, public?: true)
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      accept([:at, :naive, :day, :name])
    end
  end
end

# The domain is defined after its resources so that, when Spark's
# `__verify_spark_dsl__` hook runs for the domain, every referenced resource
# module is already compiled (Elixir >= 1.19 runs `@after_verify` eagerly per
# module while the rest of the file is still compiling).
defmodule AshClickhouse.BulkReturnDomain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(AshClickhouse.BulkReturnResource)
  end
end
