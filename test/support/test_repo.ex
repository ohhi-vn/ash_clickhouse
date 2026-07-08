defmodule AshClickhouse.TestRepo do
  @moduledoc """
  Test repo for AshClickhouse integration tests.

  Uses `AshClickhouse.Repo` with the `:ash_clickhouse` OTP app. Configuration
  is loaded from `config/test.exs` (or overridden at runtime by the integration
  test harness when connecting to a container or a direct instance).
  """
  use AshClickhouse.Repo, otp_app: :ash_clickhouse
end
