defmodule BasicApp.Domain do
  @moduledoc "Example Ash domain."
  use Ash.Domain

  resources do
    resource BasicApp.User
  end
end
