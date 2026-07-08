defmodule AshClickhouse.TestResource do
  @moduledoc """
  A simple ClickHouse-backed Ash resource used by integration tests.
  """
  use Ash.Resource,
    data_layer: AshClickhouse.DataLayer,
    domain: AshClickhouse.TestDomain

  import AshClickhouse.DataLayer.Dsl
  import Ash.Expr

  clickhouse do
    table "test_users"
    repo AshClickhouse.TestRepo
    database "ash_clickhouse_test"
    engine "MergeTree()"
    order_by "id"
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string
    attribute :email, :string
    attribute :age, :integer
    create_timestamp :inserted_at
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [:name, :email, :age]
    end

    update :update do
      accept [:name, :email, :age]
    end
  end

  aggregates do
    count :total_count, :this
    count :adult_count, :this, filter: [age: [gte: 18]]
  end
end
