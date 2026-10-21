defmodule AshClickhouse.CompatCustomer do
  @moduledoc """
  A ClickHouse-backed Ash resource used by the compatibility tests.

  It declares the features the change is about: expression calculations, a
  relationship, and a set of attributes wide enough to exercise the filter
  translation.
  """
  use Ash.Resource,
    data_layer: AshClickhouse.DataLayer,
    domain: AshClickhouse.CompatDomain,
    validate_domain_inclusion?: false

  import AshClickhouse.DataLayer.Dsl.Macros

  clickhouse do
    table("compat_customers")
    repo(AshClickhouse.FakeRepo)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string)
    attribute(:email, :string)
    attribute(:age, :integer)
    attribute(:tier, :string)
  end

  relationships do
    has_many :orders, AshClickhouse.CompatOrder do
      source_attribute(:id)
      destination_attribute(:customer_id)
    end
  end

  calculations do
    calculate(:copied_name, :string, expr(name))
    calculate(:doubled_age, :integer, expr(age * 2))
  end

  aggregates do
    count(:order_count, :orders)

    count :paid_order_count, :orders do
      filter(status: "paid")
      join_filter([:orders], total: 100)
    end

    first :first_order_total, :orders, :total do
      sort(total: :desc)
    end

    list(:order_totals, :orders, :total)

    exists :has_paid_orders, :orders do
      filter(status: "paid")
    end
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      accept([:name, :email, :age, :tier])
    end
  end
end

defmodule AshClickhouse.CompatOrder do
  @moduledoc """
  The related resource of `AshClickhouse.CompatCustomer`.
  """
  use Ash.Resource,
    data_layer: AshClickhouse.DataLayer,
    domain: AshClickhouse.CompatDomain,
    validate_domain_inclusion?: false

  import AshClickhouse.DataLayer.Dsl.Macros

  clickhouse do
    table("compat_orders")
    repo(AshClickhouse.FakeRepo)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:customer_id, :uuid)
    attribute(:status, :string)
    attribute(:total, :integer)
  end

  relationships do
    belongs_to :customer, AshClickhouse.CompatCustomer do
      source_attribute(:customer_id)
      destination_attribute(:id)
    end

    has_many :lines, AshClickhouse.CompatLine do
      source_attribute(:id)
      destination_attribute(:order_id)
    end
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      accept([:customer_id, :status, :total])
    end
  end
end

defmodule AshClickhouse.CompatLine do
  @moduledoc """
  The second hop of a two-hop relationship path, used by the relationship
  filter tests.
  """
  use Ash.Resource,
    data_layer: AshClickhouse.DataLayer,
    domain: AshClickhouse.CompatDomain,
    validate_domain_inclusion?: false

  import AshClickhouse.DataLayer.Dsl.Macros

  clickhouse do
    table("compat_lines")
    repo(AshClickhouse.FakeRepo)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:order_id, :uuid)
    attribute(:sku, :string)
  end

  actions do
    defaults([:read, :destroy])
  end
end

# The domain is defined after its resources so that, when Spark's
# `__verify_spark_dsl__` hook runs for the domain, every referenced resource
# module is already compiled.
defmodule AshClickhouse.CompatDomain do
  @moduledoc "Test domain for the ClickHouse data layer compatibility tests."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(AshClickhouse.CompatCustomer)
    resource(AshClickhouse.CompatOrder)
    resource(AshClickhouse.CompatLine)
  end
end
