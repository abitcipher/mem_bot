defmodule MemBot.Value do
  @moduledoc """
  Checks that a value can travel in MEM: JSON without floats, nested at most eight levels
  deep, with at most 1024 items in any list or map.

  The node refuses other values too; checking here gives a clear error before anything is sent.
  """

  @max_depth 8
  @max_items 1024

  @typedoc "Why a value cannot travel."
  @type error :: :float | :too_deep | :too_many_items | {:not_json, term()}

  @doc """
  `:ok`, or `{:error, reason}`.

      iex> MemBot.Value.check(%{"count" => 3, "codes" => ["A", "B"]})
      :ok
      iex> MemBot.Value.check(%{"temperature" => 4.5})
      {:error, :float}
  """
  @spec check(term()) :: :ok | {:error, error()}
  def check(value), do: check(value, 1)

  defp check(value, depth) when depth > @max_depth and (is_map(value) or is_list(value)),
    do: {:error, :too_deep}

  defp check(value, _depth) when is_float(value), do: {:error, :float}

  defp check(value, _depth)
       when is_integer(value) or is_binary(value) or is_boolean(value) or is_nil(value),
       do: :ok

  defp check(value, _depth) when is_atom(value), do: :ok

  defp check(value, depth) when is_list(value) do
    if length(value) > @max_items, do: {:error, :too_many_items}, else: all(value, depth)
  end

  defp check(value, depth) when is_map(value) and not is_struct(value) do
    cond do
      map_size(value) > @max_items ->
        {:error, :too_many_items}

      not Enum.all?(Map.keys(value), &(is_binary(&1) or is_atom(&1))) ->
        {:error, {:not_json, value}}

      true ->
        all(Map.values(value), depth)
    end
  end

  defp check(value, _depth), do: {:error, {:not_json, value}}

  defp all(values, depth) do
    Enum.reduce_while(values, :ok, fn v, :ok ->
      case check(v, depth + 1) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end
end
