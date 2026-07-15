defmodule AshClickhouse.ClickhouseContainer do
  @moduledoc """
  ClickHouse container management via `testcontainer_ex`.

  Provides a builder-style API for configuring and starting a ClickHouse
  test container. The container is started with the HTTP interface exposed on
  port 8123 and is ready once it accepts TCP connections and answers a
  `SELECT 1` query.

  ## Example

      {:ok, container} = AshClickhouse.ClickhouseContainer.start()

      host = TestcontainerEx.get_host(container)
      port = TestcontainerEx.get_port(container, 8123)

      # ... run integration tests ...

      TestcontainerEx.stop_container(container.container_id)
  """

  alias TestcontainerEx.CustomContainer
  alias TestcontainerEx.Wait

  @default_image "clickhouse/clickhouse-server:24.8"
  @http_port 8123

  defstruct [
    :image,
    :wait_timeout,
    :container
  ]

  @doc "Create a new container config with defaults."
  def new do
    %__MODULE__{
      image: @default_image,
      wait_timeout: 120_000
    }
  end

  @doc "Set the container image."
  def with_image(%__MODULE__{} = config, image), do: %{config | image: image}

  @doc "Set the wait timeout in milliseconds."
  def with_wait_timeout(%__MODULE__{} = config, timeout), do: %{config | wait_timeout: timeout}

  @doc """
  Builds a `TestcontainerEx.CustomContainer` from this config.
  """
  def to_custom_container(%__MODULE__{image: image, wait_timeout: timeout}) do
    CustomContainer.new(image)
    |> CustomContainer.with_exposed_port(@http_port)
    # Without explicit credentials the ClickHouse entrypoint disables network
    # access for the `default` user, so the HTTP interface accepts TCP but
    # refuses to serve queries. Setting a user (without a password) and enabling
    # access management keeps the `default` user reachable with no auth, which is
    # what the test repo expects.
    |> CustomContainer.with_env("CLICKHOUSE_USER", "default")
    |> CustomContainer.with_env("CLICKHOUSE_DEFAULT_ACCESS_MANAGEMENT", "1")
    |> CustomContainer.with_env("CLICKHOUSE_DB", "default")
    # Wait until ClickHouse actually answers queries, not merely until the TCP
    # port is open — the server needs several seconds after the port accepts
    # connections before it serves HTTP requests.
    |> CustomContainer.with_wait_strategy(
      Wait.http("/?query=SELECT%201", @http_port, status_code: 200, timeout: timeout)
    )
    |> CustomContainer.with_auto_remove(true)
  end

  @doc """
  Starts a ClickHouse container.

  Returns `{:ok, %__MODULE__{container: started_container_config}}` on success
  or `{:error, reason}` if the container could not be started (for example when
  no container engine is available).
  """
  def start(%__MODULE__{} = config \\ new()) do
    case Application.get_env(:testcontainer_ex, :enabled, true) do
      false ->
        {:error, :containers_disabled}

      true ->
        # Ensure the container engine is reachable and that testcontainer_ex can
        # find its socket. On macOS Podman runs in a VM and exposes its API via a
        # gvproxy socket that testcontainer_ex does not auto-detect, so we resolve
        # it and export CONTAINER_ENGINE_HOST, then reconnect the server.
        case ensure_engine_running() do
          :ok ->
            reconnect_testcontainer_ex()

            custom = to_custom_container(config)

            case TestcontainerEx.start_container(custom) do
              {:ok, container} -> {:ok, %__MODULE__{config | container: container}}
              {:error, reason} -> {:error, reason}
            end

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  # Detects a reachable container engine (Podman or Docker) and, for Podman,
  # exports its API socket as CONTAINER_ENGINE_HOST so testcontainer_ex can
  # connect to the VM-backed daemon. Returns :ok or {:error, reason}.
  defp ensure_engine_running do
    case engine_type() do
      :none ->
        {:error, :no_container_engine}

      engine ->
        reachable = System.cmd(engine_executable(engine), ["version"], stderr_to_stdout: true)

        case elem(reachable, 1) do
          0 ->
            configure_podman_host(engine)
            :ok

          _ ->
            {:error, {:engine_not_reachable, engine}}
        end
    end
  end

  defp engine_type do
    cond do
      System.find_executable("podman") != nil -> :podman
      System.find_executable("docker") != nil -> :docker
      true -> :none
    end
  end

  defp engine_executable(:podman), do: "podman"
  defp engine_executable(:docker), do: "docker"

  # Exports the Podman API socket as CONTAINER_ENGINE_HOST so testcontainer_ex
  # can reach the daemon. No-op for Docker or when already set.
  defp configure_podman_host(:podman) do
    if System.get_env("CONTAINER_ENGINE_HOST") do
      :ok
    else
      case podman_socket_path() do
        nil -> :ok
        path -> System.put_env("CONTAINER_ENGINE_HOST", "unix://" <> path)
      end
    end
  end

  defp configure_podman_host(_), do: :ok

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

  # Reconnects the TestcontainerEx server so it picks up any engine host we just
  # configured (e.g. CONTAINER_ENGINE_HOST for Podman). No-op if the server is
  # not running yet or is already connected.
  defp reconnect_testcontainer_ex do
    if Process.whereis(TestcontainerEx) do
      TestcontainerEx.reconnect([engine: engine_type()], TestcontainerEx)
    else
      :ok
    end
  rescue
    _ -> :ok
  end

  @doc "Stops a previously started container."
  def stop(%__MODULE__{container: nil}), do: :ok

  def stop(%__MODULE__{container: container}) do
    TestcontainerEx.stop_container(container.container_id)
    :ok
  end

  @doc "Returns the host the container is reachable on."
  def host(%__MODULE__{container: container}), do: TestcontainerEx.get_host(container)

  @doc "Returns the mapped host port for the ClickHouse HTTP interface."
  def port(%__MODULE__{container: container}, port \\ @http_port),
    do: TestcontainerEx.get_port(container, port)

  @doc "Returns a ClickHouse connection URL for the running container."
  def url(%__MODULE__{container: container}) do
    {host, port} = CustomContainer.endpoint(container, @http_port)
    "http://#{host}:#{port}"
  end
end
