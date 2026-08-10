defmodule AshClickhouse.MultiDomainExtensionTest do
  @moduledoc """
  Tests that `AshClickhouse.DataLayer.Extension` handles resources spread
  across multiple Ash domains, each possibly backed by a different repo.

  These exercise the realistic `mix ash.codegen` / `mix ash.migrate` scenario
  where a single application has several domains and each domain's resources
  live in their own ClickHouse repo.
  """
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO

  alias AshClickhouse.DataLayer.Extension
  alias AshClickhouse.Migration

  # ── Repos ─────────────────────────────────────────────────────────────────

  defmodule RepoA do
    def query(statement, _params) do
      send(self(), {:repo_query, "A", statement})
      {:ok, %ClickHouse.Result{raw: "", meta: %{}, compressed: false, rows: [], columns: []}}
    end

    def database, do: "domain_a_db"
  end

  defmodule RepoB do
    def query(statement, _params) do
      send(self(), {:repo_query, "B", statement})
      {:ok, %ClickHouse.Result{raw: "", meta: %{}, compressed: false, rows: [], columns: []}}
    end

    def database, do: "domain_b_db"
  end

  # ── Domain A ────────────────────────────────────────────────────────────────

  defmodule DomainA do
    @moduledoc "First test domain, backed by RepoA."
    use Ash.Domain

    resources do
      resource(AshClickhouse.MultiDomainExtensionTest.OrderA)
      resource(AshClickhouse.MultiDomainExtensionTest.ArchivedA)
    end
  end

  defmodule OrderA do
    use Ash.Resource,
      data_layer: AshClickhouse.DataLayer,
      domain: AshClickhouse.MultiDomainExtensionTest.DomainA

    import AshClickhouse.DataLayer.Dsl.Macros

    clickhouse do
      table("domain_a_orders")
      repo(AshClickhouse.MultiDomainExtensionTest.RepoA)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:total, :decimal)
      attribute(:status, :string)
    end
  end

  defmodule ArchivedA do
    # Same repo as OrderA but excluded from migrations.
    use Ash.Resource,
      data_layer: AshClickhouse.DataLayer,
      domain: AshClickhouse.MultiDomainExtensionTest.DomainA

    import AshClickhouse.DataLayer.Dsl.Macros

    clickhouse do
      table("domain_a_archived")
      repo(AshClickhouse.MultiDomainExtensionTest.RepoA)
      migrate(false)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string)
    end
  end

  # ── Domain B ────────────────────────────────────────────────────────────────

  defmodule DomainB do
    @moduledoc "Second test domain, backed by RepoB."
    use Ash.Domain

    resources do
      resource(AshClickhouse.MultiDomainExtensionTest.ProductB)
    end
  end

  defmodule ProductB do
    use Ash.Resource,
      data_layer: AshClickhouse.DataLayer,
      domain: AshClickhouse.MultiDomainExtensionTest.DomainB

    import AshClickhouse.DataLayer.Dsl.Macros

    clickhouse do
      table("domain_b_products")
      repo(AshClickhouse.MultiDomainExtensionTest.RepoB)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:sku, :string)
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  defp all_resources, do: [OrderA, ArchivedA, ProductB]

  defp capture_all(fun) do
    out =
      capture_io(fn ->
        err = capture_io(:stderr, fun)
        Process.put(:captured_err, err)
      end)

    out <> Process.get(:captured_err, "")
  end

  # ── Tests ───────────────────────────────────────────────────────────────────

  describe "codegen across multiple domains" do
    test "generates DDL for resources from every domain" do
      output =
        capture_io(fn ->
          assert Extension.codegen(["--dry-run"], all_resources()) == :ok
        end)

      assert output =~ Migration.create_table_cql(OrderA)
      assert output =~ Migration.create_table_cql(ProductB)
    end

    test "respects migrate(false) regardless of domain" do
      output =
        capture_io(fn ->
          assert Extension.codegen(["--dry-run"], all_resources()) == :ok
        end)

      refute output =~ "domain_a_archived"
    end

    test "--check fails when any domain has pending changes" do
      assert_raise Mix.Error, fn -> Extension.codegen(["--check"], all_resources()) end
    end

    test "--check passes when every domain is fully migrated" do
      defmodule OnlyArchivedA do
        use Ash.Resource,
          data_layer: AshClickhouse.DataLayer,
          domain: AshClickhouse.MultiDomainExtensionTest.DomainA

        import AshClickhouse.DataLayer.Dsl.Macros

        clickhouse do
          table("only_archived")
          repo(AshClickhouse.MultiDomainExtensionTest.RepoA)
          migrate(false)
        end

        attributes do
          uuid_primary_key(:id)
        end
      end

      assert Extension.codegen(["--check"], [OnlyArchivedA]) == :ok
    end
  end

  describe "migrate across multiple domains" do
    test "routes each domain's resources to their own repo" do
      output =
        capture_io(fn ->
          assert Extension.migrate([RepoA, RepoB], all_resources()) == :ok
        end)

      assert output =~ "Migrated #{inspect(OrderA)}"
      assert output =~ "Migrated #{inspect(ProductB)}"
    end

    test "only migrates domains whose repo is in the list" do
      output =
        capture_io(fn ->
          assert Extension.migrate([RepoA], all_resources()) == :ok
        end)

      assert output =~ "Migrated #{inspect(OrderA)}"
      refute output =~ "Migrated #{inspect(ProductB)}"
    end

    test "skips migrate(false) resources in a domain that is otherwise migrated" do
      output =
        capture_io(fn ->
          assert Extension.migrate([RepoA, RepoB], all_resources()) == :ok
        end)

      assert output =~ "Migrated #{inspect(OrderA)}"
      refute output =~ "Migrated #{inspect(ArchivedA)}"
    end

    test "migrates nothing when no repo matches any domain" do
      output =
        capture_io(fn ->
          assert Extension.migrate([], all_resources()) == :ok
        end)

      assert output == ""
    end
  end

  describe "domain resource enumeration" do
    test "Ash.Domain.Info.resources/1 lists each domain's ClickHouse resources" do
      assert AshClickhouse.MultiDomainExtensionTest.OrderA in Ash.Domain.Info.resources(
               AshClickhouse.MultiDomainExtensionTest.DomainA
             )

      assert AshClickhouse.MultiDomainExtensionTest.ProductB in Ash.Domain.Info.resources(
               AshClickhouse.MultiDomainExtensionTest.DomainB
             )
    end

    test "all resources share the ClickHouse data layer" do
      Enum.each(all_resources(), fn resource ->
        assert Ash.DataLayer.data_layer(resource) == AshClickhouse.DataLayer
      end)
    end
  end
end
