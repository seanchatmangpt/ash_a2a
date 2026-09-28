defmodule AshA2A.Semantic.CompilerBoundsTest do
  @moduledoc """
  SEC-09 court: `AshA2A.Semantic.Compiler` refuses oversized source text and
  oversized batches BEFORE any model invocation. The `:generate_object`
  seam is a real function that records each invocation in this test
  process's own mailbox; "the model was never called" is a real mailbox
  read, not an interaction mock.
  """
  use ExUnit.Case, async: true

  alias AshA2A.Semantic.{Compiler, Source}
  alias AshA2A.Test.Fixture.Echo

  defp counting_generate do
    test_pid = self()

    fn _model, _prompt, _schema, _opts ->
      send(test_pid, :model_called)
      {:error, :stop_after_count}
    end
  end

  test "text over the byte ceiling is refused and the model is never called" do
    text = String.duplicate("a", 65)

    assert {:error, %{code: :semantic_text_too_large, detail: %{bytes: 65, max_text_bytes: 64}}} =
             Compiler.compile(Echo, text,
               generate_object: counting_generate(),
               max_text_bytes: 64
             )

    refute_received :model_called
  end

  test "compile_source/3 enforces the same ceiling" do
    source = Source.new(String.duplicate("b", 100))

    assert {:error, %{code: :semantic_text_too_large}} =
             Compiler.compile_source(Echo, source,
               generate_object: counting_generate(),
               max_text_bytes: 99
             )

    refute_received :model_called
  end

  test "text at the ceiling reaches the model" do
    text = String.duplicate("c", 64)

    assert {:error, _} =
             Compiler.compile(Echo, text,
               generate_object: counting_generate(),
               max_text_bytes: 64
             )

    assert_received :model_called
  end

  test "the default ceiling is 16 KiB" do
    assert Compiler.max_text_bytes() == 16_384
  end

  test "an oversized batch is refused before any worker starts" do
    assert {:error, %{code: :semantic_batch_too_large, detail: %{count: 3, max_batch: 2}}} =
             Compiler.compile_many(Echo, ["x", "y", "z"],
               generate_object: counting_generate(),
               max_batch: 2
             )

    refute_received :model_called
  end

  test "a malformed bound (e.g. an unparsed env string) falls back to the default, not open" do
    assert Compiler.max_text_bytes(max_text_bytes: "999999999") == 16_384
    text = String.duplicate("d", 16_385)

    assert {:error, %{code: :semantic_text_too_large, detail: %{max_text_bytes: 16_384}}} =
             Compiler.compile(Echo, text,
               generate_object: counting_generate(),
               max_text_bytes: "999999999"
             )

    refute_received :model_called

    assert {:error, %{code: :semantic_batch_too_large, detail: %{max_batch: 100}}} =
             Compiler.compile_many(Echo, List.duplicate("x", 101),
               generate_object: counting_generate(),
               max_batch: :infinity
             )

    refute_received :model_called
  end

  test "refusal codes are S42-classified" do
    assert Compiler.__sa2a_refusal_codes__() == %{
             semantic_text_too_large: :refused_bounds,
             semantic_batch_too_large: :refused_bounds
           }
  end
end
