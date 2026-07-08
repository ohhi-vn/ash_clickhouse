# Test environment setup.
#
# Container engine host (CONTAINER_ENGINE / DOCKER_HOST) is auto-detected by
# testcontainer_ex. Integration tests gracefully skip when no engine is
# available or when containers are disabled.

# Ensure the repo cache ETS table exists (created by the data layer on demand,
# but tests that don't start the app need this to exist).
case :ets.whereis(:ash_clickhouse_repo_cache) do
  :undefined ->
    :ets.new(:ash_clickhouse_repo_cache, [:named_table, :public, {:read_concurrency, true}])

  _ ->
    :ok
end

# Load test support files
Code.require_file("test/support/test_repo.ex")
Code.require_file("test/support/test_resource.ex")
Code.require_file("test/support/test_domain.ex")
Code.require_file("test/support/container_engine.ex")
Code.require_file("test/support/clickhouse_container.ex")

ExUnit.start(max_cases: 1)
