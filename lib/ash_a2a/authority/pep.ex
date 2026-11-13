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

  ## Wire-point map

  1. `AshA2A.Copilot.Pipeline` — WIRED (pipeline.ex, `authority_check/2` in
     `admit_path/3`): a refusal surfaces as
     `{:refuse, %{code: :authority, reason: detail}}`.
  2. Any new external front-door before `AshA2A.Agent.build_command/4` should
     call the PEP before identity synthesis. The PEP is an outer membrane,
     not a replacement for Grant.
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
  @spec assert_standing(term(), term(), term(), term()) ::
          :ok | {:refused, :insufficient_authority, map()}
  def assert_standing(actor_id, scope, context, opts \\ [])

  def assert_standing(actor_id, scope, context, opts)
      when is_binary(actor_id) and actor_id != "" and is_list(opts) do
    with {:ok, action} <- normalize_scope(scope),
         {:ok, {mod, mod_opts}} <- resolve_source(opts) do
      run_check(mod, actor_id, action, context, mod_opts)
    else
      {:error, reason} -> {:refused, :insufficient_authority, %{reason: reason}}
    end
  end

  def assert_standing(actor_id, _scope, _context, opts) when not is_list(opts) do
    {:refused, :insufficient_authority,
     %{reason: :invalid_opts, actor_id: redact(actor_id), got: redact(opts)}}
  end

  def assert_standing(actor_id, _scope, _context, _opts) do
    {:refused, :insufficient_authority, %{reason: :invalid_actor_id, got: redact(actor_id)}}
  end

  defp run_check(mod, actor_id, action, context, mod_opts) do
    base = %{actor_id: truncate(actor_id), action: action}

    try do
      mod.check(actor_id, action, context, mod_opts)
    rescue
      e -> {:__raised, e}
    catch
      :throw, v -> {:__thrown, v}
      :exit, v -> {:__exited, v}
    else
      :ok ->
        :ok

      {:ok, _extra} ->
        :ok

      :deny ->
        {:refused, :insufficient_authority, Map.put(base, :reason, :source_deny)}

      {:deny, reason} ->
        {:refused, :insufficient_authority,
         base |> Map.put(:reason, :source_deny) |> Map.put(:deny_reason, redact(reason))}

      other ->
        invalid_return(base, other)
    end
    |> case do
      {:__raised, e} ->
        {:refused, :insufficient_authority,
         Map.merge(base, %{reason: :source_raised, got: redact(e)})}

      {:__thrown, v} ->
        {:refused, :insufficient_authority,
         Map.merge(base, %{reason: :source_threw, got: redact(v)})}

      {:__exited, v} ->
        {:refused, :insufficient_authority,
         Map.merge(base, %{reason: :source_exited, got: redact(v)})}

      other ->
        other
    end
  end

  defp invalid_return(base, other) do
    {:refused, :insufficient_authority,
     Map.merge(base, %{reason: :invalid_source_return, got: redact(other)})}
  end

  defp truncate(bin) when byte_size(bin) <= 64, do: bin
  defp truncate(bin), do: binary_part(bin, 0, 64) <> "..."

  # Bounded, inspected form: never leaks a large/raw term into refusal detail.
  defp redact(term), do: inspect(term, limit: 5, printable_limit: 64, pretty: false)

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
  @spec delegate(term(), term(), term(), term()) ::
          :ok | {:refused, :insufficient_authority, map()}
  def delegate(actor_id, scope, context, source) do
    with {:ok, {mod, _}} <- resolve_source(source: source),
         true <- source_behaviour?(mod) do
      assert_standing(actor_id, scope, context, source: source)
    else
      false ->
        {:refused, :insufficient_authority, %{reason: :delegate_not_a_source}}

      {:error, reason} ->
        {:refused, :insufficient_authority, %{reason: reason}}
    end
  end

  defp source_behaviour?(mod) do
    Code.ensure_loaded?(mod) and function_exported?(mod, :check, 4) and
      AshA2A.Authority.Source in (mod.module_info(:attributes)
                                  |> Keyword.get_values(:behaviour)
                                  |> List.flatten())
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
    case AshA2A.Authority.Source.resolve(Keyword.get(opts, :source, @default_source)) do
      {:ok, _} = ok -> ok
      {:error, _} = err -> err
    end
  end
end
