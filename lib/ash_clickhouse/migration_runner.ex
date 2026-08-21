defmodule AshClickhouse.MigrationRunner do
  @moduledoc """
  Runs generated ClickHouse migration files for a repo.

  Migrations are version-tracked in a `schema_migrations` table so each file is
  applied at most once. The same versioned pipeline backs both
  `mix ash_clickhouse.migrate` (`run/2`, output via `Mix.shell()`) and
  `AshClickhouse.Release.migrate/3` (which passes `logger: true` so output goes
  through `Logger` instead — Mix is unavailable inside a release).

  Migration modules implement `AshClickhouse.Schema`. The version comes from
  `version/0` when exported, falling back to the leading timestamp in the
  filename (e.g. `20240101120000_add_users.exs`) so files generated before
  `version/0` support still work.
  """

  require Logger

  @schema_migrations "schema_migrations"
  @default_migration_path "priv/repo/migrations"
  @loaded_migrations :ash_clickhouse_loaded_migrations

  @doc "The name of the version-tracking table."
  @spec schema_migrations_table() :: String.t()
  def schema_migrations_table, do: @schema_migrations

  @doc "DDL used to create the version-tracking table."
  @spec schema_migrations_create_sql() :: String.t()
  def schema_migrations_create_sql do
    """
    CREATE TABLE IF NOT EXISTS #{@schema_migrations} (
      version String,
      inserted_at DateTime DEFAULT now()
    ) ENGINE = MergeTree() ORDER BY version
    """
  end

  @doc "Creates the version-tracking table for a repo if it doesn't exist."
  @spec ensure_schema_migrations_table(module()) :: :ok | {:error, term()}
  def ensure_schema_migrations_table(repo) do
    case repo.query(schema_migrations_create_sql(), []) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Returns the versions already applied for a repo, sorted."
  @spec applied_versions(module()) :: [String.t()]
  def applied_versions(repo) do
    case repo.query("SELECT version FROM #{@schema_migrations}", []) do
      {:ok, %ClickHouse.Result{rows: rows}} when is_list(rows) ->
        rows
        |> Enum.map(fn
          [version] -> to_string(version)
          %{"version" => version} -> to_string(version)
          _ -> nil
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.sort()
        |> Enum.uniq()

      _ ->
        []
    end
  end

  @doc "Records a migration version as applied."
  @spec record_applied(module(), String.t()) :: :ok | {:error, term()}
  def record_applied(repo, version) do
    case repo.query("INSERT INTO #{@schema_migrations} (version) VALUES (?)", [to_string(version)]) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Removes a migration version from the tracking table (rollback)."
  @spec delete_applied(module(), String.t()) :: :ok | {:error, term()}
  def delete_applied(repo, version) do
    case repo.query("ALTER TABLE #{@schema_migrations} DELETE WHERE version = ?", [
           to_string(version)
         ]) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Loads and sorts the migration files under a path.

  Returns `[%{version: String.t(), module: module()}]` sorted by version,
  including only files that define at least one module. Modules whose version
  cannot be determined still appear (their `version` is the full filename).
  """
  @spec discover_migrations(String.t()) :: [%{version: String.t(), module: module()}]
  def discover_migrations(path) do
    path
    |> Path.join("*.exs")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map(&load_migration/1)
    |> Enum.reject(&is_nil(&1.module))
    |> Enum.sort_by(& &1.version)
  end

  @doc """
  Runs pending migrations for a repo and returns a summary.

  Creates the `schema_migrations` table if needed, skips versions already
  applied, executes `change/0` for the rest, and records each applied version.

  ## Options

  - `:migration_path` — directory containing `*.exs` migrations
    (default `"priv/repo/migrations"`)
  - `:dry_run` — log statements without executing or recording
  - `:logger` — emit output via `Logger` instead of `Mix.shell()` (for
    `AshClickhouse.Release`)

  Returns `{:ok, %{applied: [module()], skipped: [module()]}}` or
  `{:error, term()}` — a `{module(), term()}` tuple when a specific migration
  failed, or a bare `term()` when the tracking table could not be created.
  """
  @spec migrate(module(), keyword()) :: {:ok, map()} | {:error, term()}
  def migrate(repo, opts \\ []) do
    with :ok <- ensure_schema_migrations_table(repo) do
      migration_path = Keyword.get(opts, :migration_path, @default_migration_path)
      applied = applied_versions(repo)
      dry_run = Keyword.get(opts, :dry_run, false)

      migrations =
        repo_migrations(repo, migration_path)

      result =
        Enum.reduce_while(migrations, %{applied: [], skipped: []}, fn migration, acc ->
          run_migration(repo, migration, applied, dry_run, opts, acc)
        end)

      case result do
        {:error, _} = error ->
          error

        %{applied: applied, skipped: skipped} ->
          {:ok,
           %{
             applied: Enum.reverse(applied),
             skipped: Enum.reverse(skipped)
           }}
      end
    end
  end

  @doc """
  Runs pending migrations for a repo, `Mix`-style.

  Equivalent to `migrate/2` but prints through `Mix.shell()` and raises on
  failure, matching the behaviour of `mix ash_clickhouse.migrate`.
  """
  @spec run(module(), keyword()) :: :ok
  def run(repo, opts \\ []) do
    case migrate(repo, opts) do
      {:ok, %{applied: [], skipped: _}} ->
        Mix.shell().info("No pending migrations for #{inspect(repo)}")
        :ok

      {:ok, _summary} ->
        :ok

      {:error, {module, reason}} ->
        Mix.raise("Failed to apply #{inspect(module)}: #{inspect(reason)}")

      {:error, reason} ->
        Mix.raise("Failed to apply migrations for #{inspect(repo)}: #{inspect(reason)}")
    end
  end

  @doc """
  Rolls back applied migrations for a repo down to (but not including) a target
  version.

  Each rolled-back migration executes `down/0` when exported, falling back to
  `AshClickhouse.Migration.reverse_statement/1` over `change/0` for files that
  predate `down/0` support. Statements that cannot be reversed are skipped with
  a warning. `:all` (or `nil`/`0`) rolls back every applied migration.

  Returns `{:ok, %{rolled_back: [module()], skipped: [module()]}}` or
  `{:error, term()}` — a `{module(), term()}` tuple when a specific migration
  failed, or a bare `term()` when the tracking table could not be created.
  """
  @spec rollback(module(), String.t() | non_neg_integer() | :all | nil, keyword()) ::
          {:ok, map()} | {:error, term()}
  def rollback(repo, target, opts \\ []) do
    with :ok <- ensure_schema_migrations_table(repo) do
      migration_path = Keyword.get(opts, :migration_path, @default_migration_path)
      applied = applied_versions(repo)

      candidates =
        repo_migrations(repo, migration_path)
        |> Enum.filter(fn migration -> Enum.member?(applied, migration.version) end)
        |> Enum.sort_by(& &1.version, :desc)

      result =
        Enum.reduce_while(candidates, %{rolled_back: [], skipped: []}, fn migration, acc ->
          run_rollback(repo, migration, target, opts, acc)
        end)

      case result do
        {:error, _} = error ->
          error

        %{rolled_back: rolled_back, skipped: skipped} ->
          {:ok,
           %{
             rolled_back: Enum.reverse(rolled_back),
             skipped: Enum.reverse(skipped)
           }}
      end
    end
  end

  # --- internals -----------------------------------------------------------

  defp repo_migrations(repo, migration_path) do
    discover_migrations(migration_path)
    |> Enum.filter(fn %{module: module} ->
      function_exported?(module, :repo, 0) and module.repo() == repo and
        function_exported?(module, :change, 0)
    end)
  end

  defp load_migration(file) do
    case :ets.lookup(loaded_migrations_table(), file) do
      [{^file, module}] ->
        %{version: migration_version(module, file), module: module}

      [] ->
        case Code.require_file(file) do
          [{module, _} | _] ->
            :ets.insert(loaded_migrations_table(), {file, module})
            %{version: migration_version(module, file), module: module}

          _ ->
            %{version: nil, module: nil}
        end
    end
  end

  defp loaded_migrations_table do
    if :ets.whereis(@loaded_migrations) == :undefined do
      :ets.new(@loaded_migrations, [:named_table, :set, :public, read_concurrency: true])
    else
      @loaded_migrations
    end
  end

  defp migration_version(module, file) do
    if function_exported?(module, :version, 0) do
      to_string(module.version())
    else
      case Regex.run(~r/^(\d{14})/, Path.basename(file)) do
        [_, version] -> version
        _ -> Path.basename(file)
      end
    end
  end

  defp run_migration(repo, migration, applied, dry_run, opts, acc) do
    if Enum.member?(applied, migration.version) do
      {:cont, %{acc | skipped: [migration.module | acc.skipped]}}
    else
      case apply_migration(repo, migration, dry_run, opts) do
        :ok ->
          {:cont, %{acc | applied: [migration.module | acc.applied]}}

        {:error, reason} ->
          {:halt, {:error, {migration.module, reason}}}
      end
    end
  end

  defp run_rollback(repo, migration, target, opts, acc) do
    if rollback_stop?(target, migration.version) do
      {:halt, acc}
    else
      case rollback_migration(repo, migration, opts) do
        :ok ->
          {:cont, %{acc | rolled_back: [migration.module | acc.rolled_back]}}

        :skipped ->
          {:cont, %{acc | skipped: [migration.module | acc.skipped]}}

        {:error, reason} ->
          {:halt, {:error, {migration.module, reason}}}
      end
    end
  end

  defp apply_migration(repo, migration, dry_run, opts) do
    statements = migration.module.change()

    if dry_run do
      log(
        opts,
        "Would apply #{inspect(migration.module)} (#{migration.version}): " <>
          "#{length(statements)} statement(s)"
      )

      :ok
    else
      case run_statements(repo, migration.module, statements) do
        :ok ->
          case record_applied(repo, migration.version) do
            :ok ->
              log(opts, "Applied #{inspect(migration.module)} (#{migration.version})")
              :ok

            {:error, reason} ->
              {:error, "failed to record #{inspect(migration.module)}: #{inspect(reason)}"}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp rollback_migration(repo, migration, opts) do
    down = down_statements(migration.module)

    if down == [] do
      log(
        opts,
        "Skipping #{inspect(migration.module)} (#{migration.version}): " <>
          "no reversible statements"
      )

      :skipped
    else
      case run_statements(repo, migration.module, down) do
        :ok ->
          case delete_applied(repo, migration.version) do
            :ok ->
              log(opts, "Rolled back #{inspect(migration.module)} (#{migration.version})")
              :ok

            {:error, reason} ->
              {:error, "failed to remove #{inspect(migration.module)}: #{inspect(reason)}"}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp down_statements(module) do
    if function_exported?(module, :down, 0) do
      module.down()
    else
      module.change()
      |> Enum.map(&AshClickhouse.Migration.reverse_statement/1)
      |> Enum.reject(&is_nil/1)
    end
  end

  defp run_statements(repo, _module, statements) do
    Enum.reduce_while(statements, :ok, fn statement, :ok ->
      case repo.query(statement, []) do
        {:ok, _} ->
          {:cont, :ok}

        {:error, reason} ->
          {:halt, {:error, "failed executing #{statement}: #{inspect(reason)}"}}
      end
    end)
  end

  # Rollback stops once we reach a migration at or below the target version.
  # `:all`, `nil`, and `0` mean "roll back everything".
  defp rollback_stop?(:all, _version), do: false
  defp rollback_stop?(nil, _version), do: false
  defp rollback_stop?(0, _version), do: false
  defp rollback_stop?("0", _version), do: false

  defp rollback_stop?(target, version) when is_binary(target) or is_integer(target) do
    target = to_string(target)
    version = to_string(version)

    # Compare numerically when both sides parse as integers (handles
    # mixed-width `version/0` values); fall back to lexicographic order for
    # timestamp-style versions.
    case {Integer.parse(target), Integer.parse(version)} do
      {{t, ""}, {v, ""}} -> v <= t
      _ -> version <= target
    end
  end

  defp rollback_stop?(_other, _version), do: false

  defp log(opts, message) do
    if Keyword.get(opts, :logger, false) do
      Logger.info(message)
    else
      Mix.shell().info(message)
    end
  end
end
