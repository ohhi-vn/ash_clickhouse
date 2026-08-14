defmodule AshClickhouse.TestSupport.MigrationRepo do
  @moduledoc false
  # Fake repo used by MigrationRunner / Release tests. It records every
  # statement executed and simulates the `schema_migrations` tracking table
  # (INSERT records a version, ALTER ... DELETE removes one, SELECT lists them).

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Agent.start(fn -> %{versions: MapSet.new(), statements: []} end, name: name)
  end

  def stop, do: Agent.stop(__MODULE__)

  def create_database, do: {:ok, :created}

  def database, do: "test_db"

  def query("SELECT version FROM schema_migrations", []) do
    rows = versions() |> Enum.sort() |> Enum.map(&[&1])
    {:ok, result(rows)}
  end

  def query("INSERT INTO schema_migrations (version) VALUES ('" <> rest, []) do
    version = rest |> String.split("')") |> hd()

    Agent.update(__MODULE__, fn state ->
      %{state | versions: MapSet.put(state.versions, version)}
    end)

    {:ok, result([])}
  end

  def query("ALTER TABLE schema_migrations DELETE WHERE version = '" <> rest, []) do
    version = rest |> String.split("'") |> hd()

    Agent.update(__MODULE__, fn state ->
      %{state | versions: MapSet.delete(state.versions, version)}
    end)

    {:ok, result([])}
  end

  def query("CREATE TABLE IF NOT EXISTS schema_migrations" <> _, []) do
    {:ok, result([])}
  end

  def query(statement, []) do
    Agent.update(__MODULE__, fn state -> %{state | statements: [statement | state.statements]} end)

    {:ok, result([])}
  end

  def recorded_statements do
    Agent.get(__MODULE__, &Enum.reverse(&1.statements))
  end

  def reset_statements do
    Agent.update(__MODULE__, fn state -> %{state | statements: []} end)
  end

  def versions do
    Agent.get(__MODULE__, & &1.versions)
  end

  defp result(rows) do
    %ClickHouse.Result{raw: "", meta: %{}, compressed: false, rows: rows, columns: []}
  end
end
