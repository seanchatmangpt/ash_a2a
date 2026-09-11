defmodule AshA2A.MetadataKeyTest do
  use ExUnit.Case, async: true

  alias AshA2A.MetadataKey

  describe "fetch/2" do
    test "returns the value when the atom key is present" do
      assert {:ok, "widget"} = MetadataKey.fetch(%{sku: "widget"}, :sku)
    end

    test "falls back to the string key when the atom key is absent" do
      assert {:ok, "widget"} = MetadataKey.fetch(%{"sku" => "widget"}, :sku)
    end

    test "prefers the atom key when both atom and string keys are present" do
      assert {:ok, "atom-value"} =
               MetadataKey.fetch(%{"sku" => "string-value", sku: "atom-value"}, :sku)
    end

    test "returns :error when neither key is present" do
      assert :error = MetadataKey.fetch(%{}, :sku)
    end
  end

  describe "get/3" do
    test "returns the value when present under either key form" do
      assert "widget" = MetadataKey.get(%{sku: "widget"}, :sku)
      assert "widget" = MetadataKey.get(%{"sku" => "widget"}, :sku)
    end

    test "returns nil by default when neither key is present" do
      assert is_nil(MetadataKey.get(%{}, :sku))
    end

    test "returns the given default when neither key is present" do
      assert "fallback" = MetadataKey.get(%{}, :sku, "fallback")
    end
  end
end
