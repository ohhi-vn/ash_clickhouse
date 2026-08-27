defmodule AshClickhouse.ApplicationTest do
  @moduledoc "Unit tests for AshClickhouse.Application."
  use ExUnit.Case, async: false

  @app_module AshClickhouse.Application

  setup do
    # `mix test` boots the app by default while `--no-start` does not, so this
    # suite must not assume a starting state. Stop the app so `Application.start/2`
    # below gets a clean slate, and restore it afterwards so later sync tests
    # (which rely on the app-owned repo-cache ETS table) still see it running.
    was_running? =
      Enum.any?(Application.started_applications(), fn {app, _, _} -> app == :ash_clickhouse end)

    Application.stop(:ash_clickhouse)

    on_exit(fn ->
      if was_running? do
        {:ok, _} = Application.ensure_all_started(:ash_clickhouse)
      end
    end)

    # Ensure a clean start state: drop the repo cache table so
    # Application.start/2 re-creates it. Guard against a table that is already
    # gone (e.g. it was owned by a previous test process that exited).
    case :ets.whereis(:ash_clickhouse_repo_cache) do
      :undefined -> :ok
      _ -> :ets.delete(:ash_clickhouse_repo_cache)
    end

    :ok
  end

  test "start/2 creates the shared cache ETS tables and a supervisor" do
    assert {:ok, pid} = @app_module.start(:normal, [])

    assert :ets.whereis(:ash_clickhouse_repo_cache) != :undefined
    assert :ets.whereis(:ash_clickhouse_resource_metadata) != :undefined
    assert Process.whereis(AshClickhouse.Supervisor) != nil

    Supervisor.stop(pid)
  end

  test "start/2 tolerates an existing table and an already-started supervisor" do
    assert {:ok, pid} = @app_module.start(:normal, [])

    # The tables now exist; the second start must tolerate existing tables and
    # the already-started supervisor.
    assert {:error, {:already_started, ^pid}} = @app_module.start(:normal, [])

    Supervisor.stop(pid)
  end

  test "metadata cache survives the process that first reads resource metadata" do
    {:ok, _} = Application.ensure_all_started(:ash_clickhouse)
    owner = :ets.info(:ash_clickhouse_resource_metadata, :owner)
    ref = make_ref()
    parent = self()

    requester =
      spawn(fn ->
        AshClickhouse.DataLayer.Types.uuid_attribute_names(AshClickhouse.TestResource)
        send(parent, {:metadata_read, ref})
      end)

    monitor_ref = Process.monitor(requester)
    assert_receive {:metadata_read, ^ref}
    assert_receive {:DOWN, ^monitor_ref, :process, ^requester, :normal}

    assert :ets.whereis(:ash_clickhouse_resource_metadata) != :undefined
    assert :ets.info(:ash_clickhouse_resource_metadata, :owner) == owner
    assert Process.alive?(owner)
  end
end
