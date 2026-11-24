defmodule MemBot.ValueTest do
  use ExUnit.Case, async: true
  doctest MemBot.Value

  alias MemBot.Value

  test "nesting is limited to eight levels" do
    nest = fn n -> Enum.reduce(1..n, 1, fn _, acc -> [acc] end) end
    assert Value.check(nest.(8)) == :ok
    assert Value.check(nest.(9)) == {:error, :too_deep}
  end

  test "lists and maps hold at most 1024 items" do
    assert Value.check(Enum.to_list(1..1024)) == :ok
    assert Value.check(Enum.to_list(1..1025)) == {:error, :too_many_items}
  end

  test "floats anywhere are refused" do
    assert Value.check(%{"a" => [1, %{"b" => 0.1}]}) == {:error, :float}
  end

  test "only JSON values pass" do
    assert {:error, {:not_json, _}} = Value.check({1, 2})
    assert {:error, {:not_json, _}} = Value.check(%{1 => "integer key"})
    assert Value.check(%{"gs" => "0103453120000011\u001d21A"}) == :ok
  end
end
