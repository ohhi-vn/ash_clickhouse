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
    |> CustomContainer.with_env("CLICKHOUSE_DB", "default")
    |> CustomContainer.with_wait_strategy(
      Wait.port("0.0.0.0", @http_port, timeout, 500)
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
        custom = to_custom_container(config)

        case TestcontainerEx.start_container(custom) do
          {:ok, container} -> {:ok, %__MODULE__{config | container: container}}
          {:error, reason} -> {:error, reason}
        end
    end
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
    {host, port} = TestcontainerEx.endpoint(container, @http_port)
    "http://#{host}:#{port}"
  end
end
