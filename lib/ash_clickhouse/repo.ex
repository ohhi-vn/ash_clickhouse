defmodule AshClickhouse.Repo do
  @moduledoc """
  Configuration module for AshClickhouse.

  Define a repo in your application and add it to your supervision tree:

      defmodule MyApp.Repo do
        use AshClickhouse.Repo, otp_app: :my_app
      end

  Then configure it in `config/config.exs`:

      config :my_app, MyApp.Repo,
        url: "http://localhost:8123",
        database: "my_app_dev"

  ## Options

  - `:url` — ClickHouse HTTP URL (default `"http://localhost:8123"`)
  - `:username` / `:password` — credentials (default `"default"` / `""`)
  - `:database` — default database name
  - `:pool_size` — size of the connection pool (default `10`)
  """

  @type config :: keyword()

  defmacro __using__(opts) do
    otp_app = Keyword.get(opts, :otp_app)

    quote do
      @otp_app unquote(otp_app)
      @behaviour AshClickhouse.Repo

      @doc false
      @impl AshClickhouse.Repo
      def child_spec(opts) do
        conn_opts = AshClickhouse.Repo.config_to_conn_opts(__MODULE__)
        {name, conn_opts} = Keyword.pop(conn_opts, :name, __MODULE__)
        AshClickhouse.Connection.child_spec([name: name] ++ conn_opts)
      end

      @doc "Returns the configured database."
      @impl AshClickhouse.Repo
      @spec database() :: String.t() | nil
      def database do
        config = __MODULE__.config()
        Keyword.get(config, :database)
      end

      @doc "Returns the connection struct."
      @impl AshClickhouse.Repo
      @spec connection() :: AshClickhouse.Connection.t() | nil
      def connection do
        AshClickhouse.Connection.get_conn(__MODULE__)
      end

      @doc "Executes a SQL query."
      @impl AshClickhouse.Repo
      @spec query(String.t(), list(), keyword()) ::
              {:ok, ClickHouse.Query.t()} | {:error, term()}
      def query(sql, params \\ [], opts \\ []) do
        AshClickhouse.Connection.query(__MODULE__, sql, params, opts)
      end

      @doc "Executes a SQL query, raising on error."
      @impl AshClickhouse.Repo
      @spec query!(String.t(), list(), keyword()) :: ClickHouse.Query.t()
      def query!(sql, params \\ [], opts \\ []) do
        AshClickhouse.Connection.query!(__MODULE__, sql, params, opts)
      end

      @doc "Creates the database if it doesn't exist."
      @impl AshClickhouse.Repo
      @spec create_database(String.t() | nil) :: {:ok, term()} | {:error, term()}
      def create_database(database_name \\ nil) do
        database = database_name || database()
        AshClickhouse.Identifier.validate_database!(database)

        query =
          "CREATE DATABASE IF NOT EXISTS #{AshClickhouse.Identifier.quote_name(database)}"

        __MODULE__.query(query, [])
      end

      @doc "Drops the database if it exists."
      @impl AshClickhouse.Repo
      @spec drop_database(String.t() | nil) :: {:ok, term()} | {:error, term()}
      def drop_database(database_name \\ nil) do
        database = database_name || database()
        AshClickhouse.Identifier.validate_database!(database)

        query = "DROP DATABASE IF EXISTS #{AshClickhouse.Identifier.quote_name(database)}"
        __MODULE__.query(query, [])
      end

      @doc "Returns the full repo config."
      @impl AshClickhouse.Repo
      @spec config() :: keyword()
      def config do
        case Application.get_env(@otp_app, __MODULE__) do
          nil -> []
          config when is_list(config) -> config
        end
      end

      defoverridable config: 0
    end
  end

  @callback config() :: keyword()
  @callback database() :: String.t() | nil
  @callback connection() :: AshClickhouse.Connection.t() | nil
  @callback create_database(String.t() | nil) :: {:ok, term()} | {:error, term()}
  @callback drop_database(String.t() | nil) :: {:ok, term()} | {:error, term()}
  @callback child_spec(keyword()) :: Supervisor.child_spec()

  @doc "Converts repo config to ClickHouse connection options."
  @spec config_to_conn_opts(module()) :: keyword()
  def config_to_conn_opts(repo_module) do
    config = repo_module.config()

    [
      name: repo_module,
      url: Keyword.get(config, :url, "http://localhost:8123"),
      database: Keyword.get(config, :database),
      pool_timeout: Keyword.get(config, :pool_timeout, 30_000),
      ping_retry: Keyword.get(config, :ping_retry, 30_000)
    ]
  end
end
