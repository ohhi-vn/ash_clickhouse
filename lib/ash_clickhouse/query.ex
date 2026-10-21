defmodule AshClickhouse.Query do
  @moduledoc """
  Represents a pending ClickHouse query built from Ash query expressions.

  The struct is passed through the query pipeline and converted to SQL at
  execution time. `AshClickhouse.DataLayer` and
  `AshClickhouse.DataLayer.QueryBuilder` operate on `%AshClickhouse.Query{}`.
  """

  @typedoc """
  A select-list entry.

  Either a plain column name, or a `{name, sql}` pair holding an expression
  that is rendered as `<sql> AS <name>`.
  """
  @type select_entry :: atom() | {atom(), String.t()}

  @type t :: %__MODULE__{
          resource: Ash.Resource.t(),
          repo: module() | nil,
          table: String.t() | nil,
          database: String.t() | nil,
          filters: list(),
          sorts: list(),
          limit: pos_integer() | nil,
          offset: non_neg_integer() | nil,
          select: list(select_entry()) | nil,
          distinct: list(atom()) | nil,
          tenant: term(),
          context: map(),
          aggregates: list(map()),
          group_by: list(atom()) | nil,
          calculations: list(map()),
          combination: list(),
          combination_of: list(),
          distinct_sort: list()
        }

  defstruct [
    :resource,
    :repo,
    :table,
    :database,
    limit: nil,
    offset: nil,
    select: nil,
    distinct: nil,
    tenant: nil,
    context: %{},
    aggregates: [],
    group_by: nil,
    filters: [],
    sorts: [],
    calculations: [],
    combination: [],
    combination_of: [],
    distinct_sort: []
  ]

  alias AshClickhouse.DataLayer
  alias AshClickhouse.DataLayer.Dsl

  @doc "Creates a new query from a resource and repo."
  @spec new(module(), module()) :: t()
  def new(resource, repo) do
    table = DataLayer.source(resource)
    database = Dsl.database(resource)

    %__MODULE__{
      resource: resource,
      repo: repo,
      table: table,
      database: database,
      filters: []
    }
  end

  @doc "Creates a new query from just a resource (repo resolved from DSL)."
  @spec new(module()) :: t()
  def new(resource) do
    repo = Dsl.repo(resource)
    new(resource, repo)
  end
end
