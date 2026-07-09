defmodule AshClickhouse do
  @moduledoc """
  AshClickhouse — an Ash Framework data layer for ClickHouse.

  This library implements the `Ash.DataLayer` behaviour so that Ash resources
  can be backed by a ClickHouse columnar OLAP database. It uses the
  [`clickhouse`](https://hex.pm/packages/clickhouse) client under the hood.

  ## Quick start

      defmodule MyApp.Repo do
        use AshClickhouse.Repo, otp_app: :my_app
      end

      defmodule MyApp.User do
        use Ash.Resource,
          data_layer: AshClickhouse.DataLayer,
          domain: MyApp.Domain

        import AshClickhouse.DataLayer.Dsl.Macros

        clickhouse do
          table "users"
          repo MyApp.Repo
        end

        attributes do
          uuid_primary_key :id
          attribute :name, :string
          attribute :email, :string
        end

        actions do
          defaults [:create, :read, :update, :destroy]
        end
      end

  See `AshClickhouse.DataLayer` for the full list of supported features and
  `AshClickhouse.Repo` for connection configuration.
  """

  @doc """
  Returns the version of the AshClickhouse library.
  """
  def version do
    {:ok, version} = :application.get_key(:ash_clickhouse, :vsn)
    List.to_string(version)
  end
end
