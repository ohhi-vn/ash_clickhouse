defmodule BasicApp.Repo do
  @moduledoc "ClickHouse repo for the example app."
  use AshClickhouse.Repo, otp_app: :basic_app
end
