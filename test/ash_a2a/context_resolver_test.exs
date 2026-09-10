defmodule AshA2A.ContextResolverTest do
  @moduledoc """
  Real-collaborator tests for `AshA2A.ContextResolver.fetch/2`'s string-keyed
  fallback branch: `Map.fetch(metadata, key)` misses (the caller supplied the
  key as a string, not an atom, since `A2A.Message.metadata` is parsed
  straight from remote-caller JSON, per the moduledoc) and the private
  `fetch/2` helper falls back to `Map.get(metadata, Atom.to_string(key))`.

  The module's own doctest only exercises the atom-keyed happy path
  (`%{id: "user-1", tenant: "acme"}` for `auth_identity`, and implicit `%{}`
  for `metadata[:context]`); it documents the string-key fallback as
  symmetric but never actually reaches that branch. These tests reach it for
  real: `tenant_claim/1` calls `fetch(auth_identity, :tenant)`, so a
  string-keyed `auth_identity` map exercises the fallback in the `:tenant`
  path, and a string-keyed `"context"` key in `message.metadata` exercises it
  in the `:context` path.
  """

  use ExUnit.Case, async: true

  alias AshA2A.ContextResolver

  describe "from_a2a_message/4 string-keyed fallback branches" do
    test "auth_identity keyed by string \"tenant\" is read via the string-key fallback" do
      message = A2A.Message.new_user("hi")

      auth_identity = %{"id" => "user-1", "tenant" => "acme"}

      ctx =
        ContextResolver.from_a2a_message(
          message,
          AshA2A.Test.Fixture.Domain,
          [],
          auth_identity
        )

      # actor is auth_identity verbatim, regardless of key type.
      assert ctx.actor == auth_identity

      # tenant_claim/1 -> fetch(auth_identity, :tenant): Map.fetch(auth_identity, :tenant)
      # misses because the key is the string "tenant", not the atom :tenant --
      # this assertion only passes if the string-key fallback
      # (Map.get(auth_identity, Atom.to_string(:tenant))) actually ran.
      assert ctx.tenant == "acme"
    end

    test "message metadata keyed by string \"context\" is read via the string-key fallback" do
      raw_context = %{foo: 1}

      %A2A.Message{} = base_message = A2A.Message.new_user("hi")
      message = %A2A.Message{base_message | metadata: %{"context" => raw_context}}

      ctx =
        ContextResolver.from_a2a_message(
          message,
          AshA2A.Test.Fixture.Domain
        )

      # fetch(metadata, :context): Map.fetch(metadata, :context) misses because
      # the key is the string "context", not the atom :context -- this
      # assertion only passes if the string-key fallback
      # (Map.get(metadata, Atom.to_string(:context))) actually ran and
      # returned the real, non-default value (an empty map would also satisfy
      # a weaker assertion, so assert the exact raw_context contents).
      assert ctx.context == raw_context
      assert ctx.context == %{foo: 1}
    end
  end
end
