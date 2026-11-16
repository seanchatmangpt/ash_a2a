# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Sim.Auth do
  @moduledoc """
  The simulation server's test credentials: a bearer scheme, three fixed
  tokens, and the standing grants that make the mutating skills admissible.

  | Token (`tokens/0` key) | Identity | Scope `a2a:invoke` | Standing grants |
  |---|---|---|---|
  | `:writer` | `sim-writer` | yes | every `:change` and `:external_do` skill |
  | `:reader` | `sim-reader` | yes | none |
  | `:unscoped` | `sim-unscoped` | no | none |

  A call without a token is refused `401`. The `:unscoped` token is refused
  `403` (`insufficient_scope`). The `:reader` token passes authentication and
  can run `:observe` skills, but a mutating skill is refused by the authority
  gate before the Ash action runs.

  These credentials are public test fixtures. Do not reuse this module for a
  real deployment.
  """

  alias AshA2A.Protocol.SecurityScheme.HTTPAuth

  @scheme "bearer_auth"
  @scope "a2a:invoke"

  @tokens %{
    writer: "sim-writer-token",
    reader: "sim-reader-token",
    unscoped: "sim-unscoped-token"
  }

  @identities %{
    "sim-writer-token" => %{id: "sim-writer", scopes: ["a2a:invoke"]},
    "sim-reader-token" => %{id: "sim-reader", scopes: ["a2a:invoke"]},
    "sim-unscoped-token" => %{id: "sim-unscoped", scopes: []}
  }

  @doc "The bearer tokens, keyed by role (`:writer`, `:reader`, `:unscoped`)."
  @spec tokens() :: %{writer: String.t(), reader: String.t(), unscoped: String.t()}
  def tokens, do: @tokens

  @doc "The security scheme name the agent card declares."
  @spec scheme_name() :: String.t()
  def scheme_name, do: @scheme

  @doc "Options for `AshA2A.Protocol.Plug.Auth.init/1`: the bearer scheme and its scope."
  @spec plug_auth_opts() :: keyword()
  def plug_auth_opts do
    [
      schemes: %{@scheme => %HTTPAuth{scheme: "bearer"}},
      security: [%{@scheme => [@scope]}],
      verify: &__MODULE__.verify/3
    ]
  end

  @doc """
  The `verify` callback for `AshA2A.Protocol.Plug.Auth`. Answers the identity
  for a known token that carries every scope the mount requires.
  """
  @spec verify(String.t(), term(), Plug.Conn.t()) :: {:ok, map()} | {:error, term()}
  def verify(@scheme, token, conn) when is_map_key(@identities, token) do
    identity = Map.fetch!(@identities, token)
    required = Map.get(conn.assigns, :a2a_required_scopes, [])

    if Enum.all?(required, &(&1 in identity.scopes)) do
      {:ok, identity}
    else
      {:error, :insufficient_scope}
    end
  end

  def verify(_scheme, _credential, _conn), do: {:error, "unknown token"}

  @doc """
  Files the standing grant for the writer identity on every skill of
  `AshA2A.Sim.Note` that bears a consequence. Safe to call again: a grant that
  already exists is left as it is.
  """
  @spec issue_grants() :: :ok
  def issue_grants do
    subject = writer_principal()

    for skill <- AshA2A.Info.capability_index(AshA2A.Sim.Note),
        skill.consequence in [:change, :external_do] do
      unless AshA2A.Authority.Grant.granted?(subject, skill.id) do
        {:ok, _authority} = AshA2A.Authority.Grant.grant(subject, skill.id)
      end
    end

    :ok
  end

  @doc "The `AshA2A.Identity` principal the writer token authenticates as."
  @spec writer_principal() :: AshA2A.Identity.t()
  def writer_principal do
    AshA2A.Identity.principal(Map.fetch!(@identities, @tokens.writer))
  end

  @doc """
  The extended agent card provider: the public card plus one skill that only
  an authenticated caller sees.
  """
  @spec extended_card(map(), map()) :: {:ok, map()}
  def extended_card(_identity, public_card) do
    extra = %{
      "id" => "AshA2A.Sim.extended_only",
      "name" => "extended_only",
      "description" => "Listed only on the authenticated extended card",
      "tags" => ["sim"]
    }

    {:ok, Map.update(public_card, "skills", [extra], &(&1 ++ [extra]))}
  end
end
