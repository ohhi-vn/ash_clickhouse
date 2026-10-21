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
  @spec apply_calculations([map()], AshClickhouse.Query.t(), module()) :: [map()]
  def apply_calculations(records, query, resource) do
    query
    |> in_memory_calculations()
    |> Enum.reduce(records, fn calculation, acc ->
      Enum.map(acc, fn record -> apply_calculation(calculation, record, resource) end)
    end)
  end

  # The calculations that were recorded for in-memory evaluation. The layer
  # records them in the query's context; a query without any keeps its records
  # unchanged.
  @spec in_memory_calculations(AshClickhouse.Query.t()) :: [map()]
  defp in_memory_calculations(%{context: context}) when is_map(context) do
    Map.get(context, :calculations, [])
  end

  defp in_memory_calculations(_query), do: []

  defp apply_calculation(calculation, record, resource) do
    case calculate_in_memory(calculation, record, resource) do
      {:ok, value} ->
        put_calculation(record, calculation.name, value)

      {:error, reason} ->
        warn_skipped(calculation.name, reason)
        record
    end
  end

  # A calculated value belongs in the record's `calculations` map, not in the
  # record's attributes.
  defp put_calculation(record, name, value) when is_map(record) do
    calculations = Map.get(record, :calculations) || %{}

    Map.put(record, :calculations, Map.put(calculations, name, value))
  end

  defp calculate_in_memory(%{module: module, opts: opts}, record, _resource)
       when is_atom(module) do
    if function_exported?(module, :calculate, 2) do
      {:ok, module.calculate([record], opts)}
    else
      {:error, :no_calculate_function}
    end
  end

  # An expression calculation the data layer could not translate into SQL is
  # evaluated against the decoded record.
  defp calculate_in_memory(
         %{expression: expression, type: type, constraints: constraints},
         record,
         resource
       ) do
    case Ash.Expr.eval_hydrated(expression,
           record: record,
           resource: resource,
           unknown_on_unknown_refs?: true
         ) do
      {:ok, value} ->
        {:ok, cast_value(value, type, constraints)}

      :unknown ->
        {:error, :unevaluable_expression}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp calculate_in_memory(%{expr: expr}, record, _resource) when is_function(expr),
    do: {:ok, expr.(record)}

  defp calculate_in_memory(_calculation, _record, _resource),
    do: {:error, :unsupported_calculation}

  defp cast_value(value, nil, _constraints), do: value

  defp cast_value(value, type, constraints) do
    case Ash.Type.cast_stored(type, value, constraints || []) do
      {:ok, value} -> value
      _ -> value
    end
  end

  defp warn_skipped(name, reason) do
    Logger.warning(
      "AshClickhouse: skipping failed in-memory calculation #{inspect(name)}: #{inspect(reason)}"
    )

    # Return the record unchanged so downstream processing continues.
  end
end
