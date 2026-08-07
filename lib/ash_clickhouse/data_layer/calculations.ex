defmodule AshClickhouse.DataLayer.Calculations do
  @moduledoc """
  In-memory Ash calculations applied to decoded records.

  Extracted from `AshClickhouse.DataLayer`. Calculations that cannot be pushed
  down to SQL are run in Elixir after the rows are decoded; failures are logged
  rather than raising so a single bad calculation does not fail the whole query.
  """

  require Logger

  @doc """
  Applies the list of in-memory calculations to each record.
  """
  @spec apply_calculations([map()], map()) :: [map()]
  def apply_calculations(records, %{calculations: calculations}) when is_list(calculations) do
    Enum.map(records, fn record ->
      Enum.reduce(calculations, record, fn calculation, acc ->
        case calculate_in_memory(calculation, acc) do
          {:ok, value} ->
            Map.put(acc, calculation.name, value)

          {:error, reason} ->
            warn_skipped(calculation.name, reason)
            acc
        end
      end)
    end)
  end

  def apply_calculations(records, _), do: records

  defp calculate_in_memory(%{module: module, opts: opts}, record) when is_atom(module) do
    if function_exported?(module, :calculate, 2) do
      {:ok, module.calculate([record], opts)}
    else
      {:error, :no_calculate_function}
    end
  end

  defp calculate_in_memory(%{expr: expr}, record) when is_function(expr),
    do: {:ok, expr.(record)}

  defp calculate_in_memory(_, _), do: {:error, :unsupported_calculation}

  defp warn_skipped(name, reason) do
    Logger.warning(
      "AshClickhouse: skipping failed in-memory calculation #{inspect(name)}: #{inspect(reason)}"
    )

    # Return the record unchanged so downstream processing continues.
  end
end
