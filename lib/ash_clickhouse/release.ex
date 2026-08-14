defmodule AshClickhouse.Release do
  @moduledoc """
  Release task helpers for running AshClickhouse migrations in production
  without Mix installed.

  ## Usage

  Add a module like this to your project:

      defmodule MyApp.Release do
        @app :my_app

        def migrate do
          load_app()

          for repo <- repos() do
            AshClickhouse.Release.migrate(repo, repos())
          end
        end

        def rollback(repo, version) do
          load_app()
          AshClickhouse.Release.rollback(repo, version, repos())
        end

        defp repos do
          Application.fetch_env!(@app, :ash_clickhouse_repos)
        end

        defp load_app do
          Application.load(@app)
        end
      end

  Then run it from your release:

      bin/my_app eval "MyApp.Release.migrate"

  ## Configuration

  In your config:

      config :my_app, :ash_clickhouse_repos, [MyApp.Repo]

  Or configure per-repo:

      config :my_app, MyApp.Repo,
        url: "http://clickhouse:8123",
        database: "my_app_prod"

  ## Migration Flow

  `migrate/3` runs the generated migration files under
  `priv/repo/migrations` (overridable via the `:migration_path` option) through
  `AshClickhouse.MigrationRunner`. Each migration is tracked in a
  `schema_migrations` table, so already-applied files are skipped. Supports
  `:dry_run`, `:create_database`, and `:migration_path` options.

  ## Rollback

  `rollback/3` rolls applied migrations back to a target version using the
  `down/0` statements generated for each migration. For migration files that
  predate `down/0` support, `AshClickhouse.Migration.reverse_statement/1`
  derives inverse statements from `change/0`; statements that cannot be
  reversed are skipped with a warning.
  """

  require Logger

  alias AshClickhouse.MigrationRunner

  @doc """
  Runs pending migrations for a repo.

  ## Options

  - `:migration_path` - directory containing `*.exs` migrations
    (default: the repo app's `priv/repo/migrations`)
  - `:create_database` - create the database before migrating (default `true`)
  - `:dry_run` - if true, only log statements without executing

  ## Examples

      AshClickhouse.Release.migrate(MyApp.Repo, [MyApp.Repo])

      AshClickhouse.Release.migrate(MyApp.Repo, [MyApp.Repo], dry_run: true)
  """
  @spec migrate(module(), [module()], keyword()) :: :ok | {:error, term()}
  def migrate(repo, _all_repos, opts \\ []) do
    Logger.info("AshClickhouse.Release: Starting migration for #{inspect(repo)}")

    if Keyword.get(opts, :create_database, true) do
      if repo_supports_create_database?(repo) do
        case create_database(repo, opts) do
          :ok ->
            Logger.info("AshClickhouse.Release: Database ready")

          {:error, reason} ->
            Logger.error("AshClickhouse.Release: Failed to create database: #{inspect(reason)}")
        end
      else
        Logger.info(
          "AshClickhouse.Release: #{inspect(repo)} does not implement create_database/0, " <>
            "skipping database creation"
        )
      end
    end

    ensure_repo_started(repo)

    dry_run = Keyword.get(opts, :dry_run, false)

    if dry_run do
      Logger.info("AshClickhouse.Release: DRY RUN - no changes will be made")
    end

    runner_opts = [
      migration_path: migration_path(repo, opts),
      dry_run: dry_run,
      logger: true
    ]

    case MigrationRunner.migrate(repo, runner_opts) do
      {:ok, %{applied: applied, skipped: skipped}} ->
        Logger.info("""
        AshClickhouse.Release: Migration complete for #{inspect(repo)}
          #{length(applied)} applied
          #{length(skipped)} skipped (already applied)
        """)

        :ok

      {:error, {module, reason}} ->
        Logger.error(
          "AshClickhouse.Release: Migration failed for #{inspect(repo)}: " <>
            "#{inspect(module)} - #{inspect(reason)}"
        )

        {:error, "Migration failed for #{inspect(repo)}: #{inspect(reason)}"}

      {:error, reason} ->
        Logger.error(
          "AshClickhouse.Release: Migration failed for #{inspect(repo)}: #{inspect(reason)}"
        )

        {:error, "Migration failed for #{inspect(repo)}: #{inspect(reason)}"}
    end
  end

  @doc """
  Rolls back applied migrations to a specific version.

  `version` is the target version to roll back *to* — migrations applied after
  it are rolled back. Pass `:all`, `nil`, or `0` to roll back every applied
  migration. Each rolled-back migration executes its `down/0` statements and is
  removed from the `schema_migrations` table.

  ## Examples

      AshClickhouse.Release.rollback(MyApp.Repo, 20240101000000, [MyApp.Repo])

      AshClickhouse.Release.rollback(MyApp.Repo, :all, [MyApp.Repo])
  """
  @spec rollback(module(), String.t() | non_neg_integer() | :all | nil, [module()], keyword()) ::
          :ok | {:error, term()}
  def rollback(repo, version, _all_repos, opts \\ []) do
    Logger.info(
      "AshClickhouse.Release: Rolling back #{inspect(repo)} to version #{inspect(version)}"
    )

    ensure_repo_started(repo)

    runner_opts = [migration_path: migration_path(repo, opts), logger: true]

    case MigrationRunner.rollback(repo, version, runner_opts) do
      {:ok, %{rolled_back: rolled_back, skipped: skipped}} ->
        Logger.info("""
        AshClickhouse.Release: Rollback complete for #{inspect(repo)}
          #{length(rolled_back)} rolled back
          #{length(skipped)} skipped (no reversible statements)
        """)

        :ok

      {:error, {module, reason}} ->
        Logger.error(
          "AshClickhouse.Release: Rollback failed for #{inspect(repo)}: " <>
            "#{inspect(module)} - #{inspect(reason)}"
        )

        {:error, "Rollback failed for #{inspect(repo)}: #{inspect(reason)}"}

      {:error, reason} ->
        Logger.error(
          "AshClickhouse.Release: Rollback failed for #{inspect(repo)}: #{inspect(reason)}"
        )

        {:error, "Rollback failed for #{inspect(repo)}: #{inspect(reason)}"}
    end
  end

  @doc """
  Creates the database for a repo if it doesn't exist.

  ## Examples

      AshClickhouse.Release.create_database(MyApp.Repo)
  """
  @spec create_database(module(), keyword()) :: :ok | {:error, term()}
  def create_database(repo, _opts \\ []) do
    Logger.info("AshClickhouse.Release: Creating database for #{inspect(repo)}")

    if repo_supports_create_database?(repo) do
      case repo.create_database() do
        {:ok, _} ->
          Logger.info("AshClickhouse.Release: Database created successfully")
          :ok

        {:error, reason} ->
          Logger.error("AshClickhouse.Release: Failed to create database: #{inspect(reason)}")
          {:error, reason}
      end
    else
      Logger.warning(
        "AshClickhouse.Release: #{inspect(repo)} does not implement create_database/0, " <>
          "skipping database creation"
      )

      {:error, :create_database_not_supported}
    end
  end

  @doc """
  Returns the AshClickhouse resources for the given repos.

  Uses the `:resources` option when provided, otherwise scans loaded
  applications for modules that export `__ash_clickhouse__/1`.
  """
  @spec find_resources([module()], keyword()) :: [module()]
  def find_resources(_all_repos, opts) do
    case Keyword.get(opts, :resources) do
      nil ->
        auto_discover_resources()

      resources when is_list(resources) ->
        resources
    end
  end

  @doc false
  defp repo_supports_create_database?(repo) do
    function_exported?(repo, :create_database, 0) or
      function_exported?(repo, :create_database, 1)
  end

  @doc false
  defp auto_discover_resources do
    apps = Application.loaded_applications()

    for {app, _, _} <- apps,
        module <- get_app_modules(app),
        Code.ensure_compiled(module) == {:module, module},
        function_exported?(module, :__ash_clickhouse__, 1),
        do: module
  rescue
    _ -> []
  end

  defp get_app_modules(app) do
    case :application.get_key(app, :modules) do
      {:ok, modules} when is_list(modules) -> modules
      :undefined -> []
    end
  end

  @doc false
  defp ensure_repo_started(repo) do
    if function_exported?(repo, :__ash_clickhouse_repo__, 0) do
      ensure_hackney_started()

      case AshClickhouse.Connection.get_conn(repo) do
        %AshClickhouse.Connection{} ->
          :ok

        nil ->
          conn_opts = AshClickhouse.Repo.config_to_conn_opts(repo)

          case AshClickhouse.Connection.start_link(conn_opts) do
            {:ok, _pid} ->
              :ok

            {:error, {:already_started, _pid}} ->
              :ok

            {:error, reason} ->
              Logger.warning(
                "AshClickhouse.Release: could not start connection for #{inspect(repo)}: " <>
                  "#{inspect(reason)}. Migrations that query the cluster may fail."
              )
          end
      end
    else
      :ok
    end
  end

  defp ensure_hackney_started do
    case Application.ensure_all_started(:hackney) do
      {:ok, _apps} ->
        :ok

      {:error, reason} ->
        Logger.warning("AshClickhouse.Release: could not start :hackney: #{inspect(reason)}")
    end
  end

  # Resolves the migration directory. Explicit `:migration_path` wins, then the
  # repo app's `priv/repo/migrations` (reliable inside a release, where the
  # working directory differs from the project root), then a relative path.
  defp migration_path(repo, opts) do
    case Keyword.get(opts, :migration_path) do
      nil -> default_migration_path(repo)
      path -> path
    end
  end

  defp default_migration_path(repo) do
    otp_app =
      if function_exported?(repo, :otp_app, 0) do
        repo.otp_app()
      else
        nil
      end

    case otp_app do
      nil ->
        "priv/repo/migrations"

      app ->
        try do
          Path.join(:code.priv_dir(app), "repo/migrations")
        rescue
          _ -> "priv/repo/migrations"
        end
    end
  end
end
