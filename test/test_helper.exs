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

# Load test support files. They are required explicitly here (rather than via
# `elixirc_paths`) so they are guaranteed to be loaded for every test, including
# when a single test file is run with an explicit path filter. Requiring them
# here avoids relying on `elixirc_paths` and the "redefining module" warnings
# that double-compilation would otherwise produce.
for file <- Path.wildcard(Path.join("test/support", "**/*.ex")) do
  Code.require_file(file)
end

ExUnit.start(max_cases: 1)
