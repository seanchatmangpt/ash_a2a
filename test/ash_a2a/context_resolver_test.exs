# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ContextResolverTest do
  @moduledoc """
  Real-collaborator tests for `AshA2A.ContextResolver.fetch/2`'s string-keyed
  fallback branch: `Map.fetch(metadata, key)` misses (the caller supplied the
  key as a string, not an atom, since `AshA2A.Protocol.Message.metadata` is parsed
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
      message = AshA2A.Protocol.Message.new_user("hi")

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

      %AshA2A.Protocol.Message{} = base_message = AshA2A.Protocol.Message.new_user("hi")
      message = %AshA2A.Protocol.Message{base_message | metadata: %{"context" => raw_context}}

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
      #
      # SEC-11: the caller-supplied map is namespaced under
      # `:a2a_client_context`, never merged at the top level.
      assert ctx.context == %{a2a_client_context: raw_context}
      assert ctx.context == %{a2a_client_context: %{foo: 1}}
      refute Map.has_key?(ctx.context, :foo)
    end

    test "a caller cannot place a top-level key into the Ash context (SEC-11)" do
      message = %{AshA2A.Protocol.Message.new_user("hi") | metadata: %{"context" => %{"authorize?" => false}}}
      ctx = ContextResolver.from_a2a_message(message, AshA2A.Test.Fixture.Domain)

      assert Map.keys(ctx.context) == [:a2a_client_context]
      assert ctx.context.a2a_client_context == %{"authorize?" => false}
    end

    test "non-map context or non-map metadata resolves to an empty context, never raises" do
      bad_ctx = %{AshA2A.Protocol.Message.new_user("hi") | metadata: %{"context" => "x"}}
      assert ContextResolver.from_a2a_message(bad_ctx, AshA2A.Test.Fixture.Domain).context == %{}

      bad_md = %{AshA2A.Protocol.Message.new_user("hi") | metadata: [1]}
      assert ContextResolver.from_a2a_message(bad_md, AshA2A.Test.Fixture.Domain).context == %{}
    end
  end
end
