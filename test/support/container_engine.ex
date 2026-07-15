defmodule AshClickhouse.Test.ContainerEngine do
  @moduledoc """
  Container engine detection and health checks for test containers.

  Supports Docker and Podman via `testcontainer_ex`. The engine is
  auto-detected by `testcontainer_ex`, but this module provides a thin
  helper so integration tests can decide whether to skip gracefully when no
  container engine is reachable.

  On macOS, Podman runs inside a virtual machine and exposes its API through a
  gvproxy socket (e.g. `/var/folders/.../T/podman/podman-machine-default-api.sock`)
  rather than a well-known path. `testcontainer_ex`'s socket auto-detection does
  not look there, so `configure!/0` resolves the real socket and exports it as
  `CONTAINER_ENGINE_HOST` before any container is started.
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
      :podman -> System.cmd("podman", ["version"], stderr_to_stdout: true) |> elem(1) == 0
      :docker -> System.cmd("docker", ["version"], stderr_to_stdout: true) |> elem(1) == 0
    end
  end

  @doc """
  Ensures the container engine is running and configured for `testcontainer_ex`.

  When Podman is the engine, resolves its API socket and exports it as
  `CONTAINER_ENGINE_HOST` so `testcontainer_ex` can connect to the VM-backed
  daemon. Returns `:ok` or `{:error, reason}`.
  """
  def ensure_running do
    case engine_type() do
      :none ->
        {:error, :no_container_engine}

      engine ->
        case reachable?() do
          true ->
            configure!()
            :ok

          false ->
            {:error, {:engine_not_reachable, engine}}
        end
    end
  end

  # Exports the Podman API socket as `CONTAINER_ENGINE_HOST` so testcontainer_ex
  # can reach the daemon. No-op for Docker (testcontainer_ex finds the Docker
  # socket on its own) or when the variable is already set.
  defp configure! do
    case engine_type() do
      :podman -> configure_podman_host()
      _ -> :ok
    end
  end

  defp configure_podman_host do
    if System.get_env("CONTAINER_ENGINE_HOST") do
      :ok
    else
      case podman_socket_path() do
        nil -> :ok
        path -> System.put_env("CONTAINER_ENGINE_HOST", "unix://" <> path)
      end
    end
  end

  # `podman info` reports the configured socket, but on macOS the live gvproxy
  # socket lives under `/var/folders/.../T/podman/`. Prefer the glob match of
  # the running socket; fall back to the path podman reports.
  defp podman_socket_path do
    case Path.wildcard("/var/folders/*/*/T/podman/podman-machine-*-api.sock") do
      [path | _] -> path
      [] -> reported_podman_socket()
    end
  end

  defp reported_podman_socket do
    case System.cmd("podman", ["info", "--format", "{{.Host.RemoteSocket.Path}}"],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        output
        |> String.trim()
        |> String.trim_leading("unix://")
        |> case do
          "" -> nil
          path -> path
        end

      _ ->
        nil
    end
  end
end
