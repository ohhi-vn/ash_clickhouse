defmodule BasicApp.User do
  @moduledoc "Example resource backed by ClickHouse."
  use Ash.Resource,
    data_layer: AshClickhouse.DataLayer,
    domain: BasicApp.Domain

  import AshClickhouse.DataLayer.Dsl

  clickhouse do
    table "users"
    repo BasicApp.Repo
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
    defaults [:create, :read, :update, :destroy]
    default_accept :*
  end

  aggregates do
    count :total_count
    count :adult_count, filter: [age: [gte: 18]]
  end
end
