defmodule AshClickhouse.Test.ContainerEngine do
  @moduledoc """
  Container engine detection and health checks for test containers.

  Supports Docker and Podman via `testcontainer_ex`. The engine is
  auto-detected by `testcontainer_ex`, but this module provides a thin
  helper so integration tests can decide whether to skip gracefully when no
  container engine is reachable.
  """

  @doc "Returns the detected container engine type."
  def engine_type do
    case System.find_executable("podman") do
      nil ->
        case System.find_executable("docker") do
          nil -> :none
          _ -> :docker
        end

      _ ->
        :podman
    end
  end

  @doc "Returns true if the container engine is reachable."
  def reachable? do
    case engine_type() do
      :none -> false
      :podman -> System.cmd("podman", ["version"], stderr_to_stdout: true) |> elem(0) == 0
      :docker -> System.cmd("docker", ["version"], stderr_to_stdout: true) |> elem(0) == 0
    end
  end

  @doc "Ensure the container engine is running. Returns :ok or {:error, reason}."
  def ensure_running do
    case engine_type() do
      :none ->
        {:error, :no_container_engine}

      engine ->
        case reachable?() do
          true -> :ok
          false -> {:error, {:engine_not_reachable, engine}}
        end
    end
  end
end
