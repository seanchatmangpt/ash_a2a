# SPDX-FileCopyrightText: 2026 ash_a2a contributors
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Authority.PEP do
  @moduledoc """
  Policy Enforcement Point seam: one typed admission hop in front of any
  admit path (Copilot.Pipeline, Agent front-door, CommandBus callers).

  ## Census preamble (lane Z8, 2026-11-07)

  What EXISTS in ash_a2a (read before adding any further authority machinery):

  - `AshA2A.Authority` — authority evidence struct bound to principal and
    capability; its `from_verified_identity/2` is a constructor, not a grant
    decision.
  - `AshA2A.Agent.build_command/4` → `AshA2A.Authority.Grant.authorize/3` is
    the real dispatch-path grant decision; `AshA2A.CommandBus` revalidates
    against the same broker immediately before DO (see `admitted_by` in
    `AshA2A.Authority`).
  - `AshA2A.Authority.Grant` — policy modes over a configured
    `AshA2A.Authority.Broker` behaviour (issue/revoke/verify/granted?/renew/
    grant_expires_at/list_grants callbacks; `AshA2A.Authority.Broker.InMemory`
    reference implementation).
  - `AshA2A.Authority.TwoPortGate` — conjunctive Command x Lease gate with
    typed refusal codes (`__sa2a_refusal_codes__`).
  - `AshA2A.AuthZEN.*` — AuthZEN surface under `lib/ash_a2a/authzen/`
    (authority_policy, decision_gate, decision_pool, monotonic, wire,
    policy_evidence, receipt, projection, absorption, types).
  - `AshA2A.Hilt.WorkOrder` — work-order admission: `admit_command/2` +
    `identity_digest/1` (the digest anchor used by `pin_graph_digest/2`).
  - `AshA2A.ReceiptStore.Ekv` — durable receipt/claim store (the only "ekv"
    surface; NOT an authority source).
  - **Census negative**: nothing named `dev_authority_ekv` exists anywhere in
    lib/ or test/ of this checkout. I9's census claim is not reproducible
    here. The closest real surface is `AshA2A.ReceiptStore.Ekv`.
  - `AshA2A.CommandBus` exists (contrary to some architecture claims that it
    does not) and is the pre-DO revalidation site.

  ## Wire-point map (documentation only — NO wiring landed in this lane)

  Where `assert_standing/3` should be called before admit:

  1. `AshA2A.Copilot.Pipeline.check/3` (lib/ash_a2a/copilot/pipeline.ex) —
     at the top of `check/3`, before any state read/mutation. Today `check/3`
     has NO authority hop. On refusal, return
     `{:refused, :insufficient_authority, detail}` instead of a pipeline
     decision.
  2. Any new external front-door before `AshA2A.Agent.build_command/4` —
     `build_command` already goes through `Grant.authorize/3` internally, but
     an unprincipaled caller should be refused BEFORE identity synthesis.
     The PEP is an outer membrane, not a replacement for Grant.
  3. Do NOT double-gate inside `AshA2A.CommandBus` — it already revalidates
     against `admitted_by` immediately before DO.

  ## Contract

  `assert_standing(actor_id, scope, context, opts \\ [])`:

  - `actor_id` — opaque binary principal identifier; the Source interprets it.
  - `scope` — a binary scope string (`"a2a:task.send"` form), or a map with a
    required binary `:action` key (`%{action: "a2a:task.send", ...}`). Any
    other shape (nil, atom, integer, list) → typed refusal, never raise.
  - `context` — passed through to the Source opaquely.
  - Returns `:ok` | `{:refused, :insufficient_authority, detail}`.

  Backed by the `AshA2A.Authority.Source` behaviour. **Default source is
  `AshA2A.Authority.Source.DenyAll`: out of the box the PEP refuses
  EVERYTHING. You must explicitly configure an allow-source.**
  `AshA2A.Authority.Source.AllowAll` exists for tests only.
  """

  @default_source AshA2A.Authority.Source.DenyAll

  @doc """
  Admit or refuse `{actor_id, scope, context}` against the configured source.

  ## Options

  - `:source` — module or `{module, opts}` (default `#{inspect(@default_source)}`).
  """
  @spec assert_standing(term(), term(), term(), keyword()) ::
          :ok | {:refused, :insufficient_authority, map()}
  def assert_standing(actor_id, scope, context, opts \\ []) when is_list(opts) do
    case normalize_scope(scope) do
      {:ok, action} ->
        {mod, mod_opts} = resolve_source(opts)

        case mod.check(actor_id, action, context, mod_opts) do
          :ok -> :ok
          {:ok, _extra} -> :ok
          :deny ->
            {:refused, :insufficient_authority,
             %{reason: :source_deny, actor_id: actor_id, action: action}}

          other ->
            {:refused, :insufficient_authority,
             %{reason: :invalid_source_return, actor_id: actor_id, action: action, got: other}}
        end

      {:error, reason} ->
        {:refused, :insufficient_authority, %{reason: reason}}
    end
  end

  @doc """
  Pin a `AshA2A.Hilt.WorkOrder` identity digest as an anchor on the standing
  assertion. Passthrough to `AshA2A.Hilt.WorkOrder.identity_digest/1`, which
  exists (census: pinned, not pending).
  """
  @spec pin_graph_digest(AshA2A.Hilt.WorkOrder.t(), keyword()) ::
          {:ok, binary()} | {:error, term()}
  def pin_graph_digest(%AshA2A.Hilt.WorkOrder{} = work_order, opts \\ [])
      when is_list(opts) do
    digest = AshA2A.Hilt.WorkOrder.identity_digest(work_order)
    _ = opts
    {:ok, digest}
  end

  @doc """
  Delegate standing to a downstream module that must itself be a Source.
  Refuses if the delegate returns anything but :ok / {:ok, _} / :deny.
  """
  @spec delegate(term(), term(), term(), {module(), keyword()} | module()) ::
          :ok | {:refused, :insufficient_authority, map()}
  def delegate(actor_id, scope, context, source) do
    assert_standing(actor_id, scope, context, source: source)
  end

  # -- internals ---------------------------------------------------------

  defp normalize_scope(scope) when is_binary(scope) do
    if scope == "",
      do: {:error, :invalid_scope},
      else: {:ok, scope}
  end

  defp normalize_scope(scope) when is_map(scope) and not is_struct(scope) do
    case Map.fetch(scope, :action) do
      {:ok, action} when is_binary(action) and action != "" ->
        {:ok, action}

      {:ok, other} ->
        {:error, {:invalid_scope_action, other}}

      :error ->
        {:error, {:invalid_scope_missing_action, Map.keys(scope)}}
    end
  end

  defp normalize_scope(_other), do: {:error, :invalid_scope}

  defp resolve_source(opts) do
    case Keyword.get(opts, :source, @default_source) do
      {mod, mod_opts} when is_atom(mod) and is_list(mod_opts) -> {mod, mod_opts}
      mod when is_atom(mod) -> {mod, []}
    end
  end
end
