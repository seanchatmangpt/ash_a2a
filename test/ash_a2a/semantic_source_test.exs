defmodule AshA2A.Semantic.SourceTest do
  use ExUnit.Case, async: true

  alias AshA2A.Semantic.Source

  describe "new/2" do
    test "defaults media_type, provenance, observed_at and produces a 64-char lowercase hex id" do
      source = Source.new("hello world")

      assert source.text == "hello world"
      assert source.media_type == "text/plain"
      assert source.provenance == %{}
      assert source.observed_at == nil
      assert is_binary(source.id)
      assert String.length(source.id) == 64
      assert source.id == String.downcase(source.id)
      assert source.id =~ ~r/^[0-9a-f]{64}$/
    end

    test "identical text/media_type/provenance produce the same id" do
      opts = [media_type: "text/markdown", provenance: %{origin: "test"}]

      source_a = Source.new("same content", opts)
      source_b = Source.new("same content", opts)

      assert source_a.id == source_b.id
    end

    test "an explicit :id opt overrides fingerprinting exactly" do
      source = Source.new("some text", id: "explicit-id-123")

      assert source.id == "explicit-id-123"
    end

    test "an explicit non-string atom :id is coerced via to_string/1" do
      source = Source.new("some text", id: :my_atom_id)

      assert source.id == "my_atom_id"
    end

    test "different text produces a different id" do
      opts = [media_type: "text/plain", provenance: %{}]

      source_a = Source.new("text one", opts)
      source_b = Source.new("text two", opts)

      refute source_a.id == source_b.id
    end

    test "different provenance produces a different id" do
      source_a = Source.new("same text", provenance: %{origin: "a"})
      source_b = Source.new("same text", provenance: %{origin: "b"})

      refute source_a.id == source_b.id
    end
  end

  describe "uri/1" do
    test "returns urn:ash-a2a:source: prefixed id" do
      source = Source.new("some text", id: "abc123")

      assert Source.uri(source) == "urn:ash-a2a:source:abc123"
    end
  end
end
