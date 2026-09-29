defmodule Actuator.Fence do
  @moduledoc """
  The 16-check final actuation fence (RFC-SA2A-006 s16, RFC-SA2A-007 E-D/E-E/E-J/E-K).

  Each check is its OWN public function `check_NN_*(ctx, req, view) :: :ok | {:error, code}`
  so a court can mutate one field and prove that exactly that check refuses it. `run/4`
  evaluates them in order and stops at the first refusal: `{:error, check_number, code}`.
  `opts[:skip]` exists for courts only (necessity proofs); `Actuator.Store` never passes it.

  Inputs the checks trust: the actuator's own `Actuator.Context` (pinned registry,
  policy epoch, revocation view, clock) and its own durable `view`
  (`%{record: record | nil, nonce_owner: %{{kid, nonce} => instance_id}}`). Nothing the
  candidate or control plane asserts substitutes for either.

  Crypto boundary: signatures are verified through `Sa2aCrypto.verify_envelope/4`, which only
  certifies standing. Time policy (skew, TTL) is owned by check 12, so the substrate is
  handed a `now` clamped into the certificate window; check 10 owns "signature verifies",
  check 11 owns "enough distinct custodians", check 13 owns revocation.
  """
  alias Actuator.{Certificate, Context, Effect, EffectorRegistry}

  defmodule Request do
    @moduledoc false
    @enforce_keys [:effect, :bytes, :cert]
    defstruct @enforce_keys
  end

  @protocol_version 1
  @instance_re ~r/\A[A-Za-z0-9_.:-]{8,128}\z/

  @checks [
    {1, :check_01_protocol_version},
    {2, :check_02_effect_digest},
    {3, :check_03_principal},
    {4, :check_04_subject},
    {5, :check_05_capability},
    {6, :check_06_consequence_class},
    {7, :check_07_effect_instance},
    {8, :check_08_resource_bounds},
    {9, :check_09_policy_epoch},
    {10, :check_10_signatures},
    {11, :check_11_quorum},
    {12, :check_12_validity_window},
    {13, :check_13_revocation},
    {14, :check_14_claim_ownership},
    {15, :check_15_not_completed},
    {16, :check_16_generation}
  ]

  def checks, do: @checks

  @spec parse(binary(), binary()) :: {:ok, Request.t()} | {:error, atom()}
  def parse(effect_bytes, cert_bytes) do
    with {:ok, e} <- Effect.decode(effect_bytes), {:ok, c} <- Certificate.decode(cert_bytes) do
      {:ok, %Request{effect: e, bytes: effect_bytes, cert: c}}
    end
  end

  @spec run(Context.t(), Request.t(), map(), keyword()) :: :ok | {:error, pos_integer(), atom()}
  def run(ctx, req, view, opts \\ []) do
    skip = Keyword.get(opts, :skip, [])

    Enum.reduce_while(@checks, :ok, fn {n, fun}, :ok ->
      if n in skip do
        {:cont, :ok}
      else
        case apply(__MODULE__, fun, [ctx, req, view]) do
          :ok -> {:cont, :ok}
          {:error, code} -> {:halt, {:error, n, code}}
        end
      end
    end)
  end

  # 1 -- protocol version (effect and certificate)
  def check_01_protocol_version(_ctx, %{effect: e, cert: c}, _view) do
    if e.v == @protocol_version and c.v == @protocol_version,
      do: :ok,
      else: {:error, :unsupported_protocol_version}
  end

  # 2 -- canonical digest recomputed from the bytes the actuator will execute
  def check_02_effect_digest(_ctx, %{bytes: bytes, cert: c}, _view) do
    if Effect.digest(bytes) == c.effect_digest, do: :ok, else: {:error, :effect_digest_mismatch}
  end

  # 3 -- principal survives to the actuator: effect principal == certificate principal
  def check_03_principal(_ctx, %{effect: e, cert: c}, _view) do
    if e.principal == c.principal and e.principal != "",
      do: :ok,
      else: {:error, :principal_mismatch}
  end

  # 4 -- exact subject: must be one the actuator is configured to act on (exact match)
  def check_04_subject(ctx, %{effect: e}, _view) do
    if e.subject in ctx.allowed_subjects, do: :ok, else: {:error, :subject_not_allowed}
  end

  # 5 -- capability: the effector's own capability, and one this actuator is allowed to run
  def check_05_capability(ctx, %{effect: e}, _view) do
    with {:ok, spec} <- EffectorRegistry.fetch(e.effect_type),
         true <- e.capability == spec.capability,
         true <- ctx.allowed_capabilities == :all or e.capability in ctx.allowed_capabilities do
      :ok
    else
      _ -> {:error, :capability_mismatch}
    end
  end

  # 6 -- consequence class must be the class the effector is registered under
  def check_06_consequence_class(_ctx, %{effect: e}, _view) do
    case EffectorRegistry.fetch(e.effect_type) do
      {:ok, spec} when spec.consequence_class == e.consequence_class -> :ok
      _ -> {:error, :consequence_class_mismatch}
    end
  end

  # 7 -- effect-instance identity is well formed (it keys the durable claim and ledger)
  def check_07_effect_instance(_ctx, %{effect: e}, _view) do
    if Regex.match?(@instance_re, e.effect_instance_id),
      do: :ok,
      else: {:error, :bad_effect_instance}
  end

  # 8 -- resource bounds: declared <= actuator ceiling, actual params <= declared
  def check_08_resource_bounds(_ctx, %{effect: e}, _view) do
    declared = e.resource_bounds["max_bytes"]

    with {:ok, spec} <- EffectorRegistry.fetch(e.effect_type),
         true <- declared <= spec.max_bytes,
         true <- spec.module.size(e.params) <= declared do
      :ok
    else
      _ -> {:error, :resource_bounds_exceeded}
    end
  end

  # 9 -- policy epoch: effect and certificate both equal the actuator-held epoch
  def check_09_policy_epoch(ctx, %{effect: e, cert: c}, _view) do
    if e.policy_epoch == ctx.policy_epoch and c.policy_epoch == ctx.policy_epoch,
      do: :ok,
      else: {:error, :policy_epoch_stale}
  end

  # 10 -- every presented signature verifies against the actuator's PINNED registry.
  # Keys are never read from the certificate (its schema has no key field).
  def check_10_signatures(ctx, %{cert: c}, _view) do
    Enum.find_value(verify_all(ctx, c), :ok, fn
      {_sig, {:valid, _}} -> nil
      {_sig, {:invalid, code}} -> {:error, code}
    end)
  end

  # 11 -- quorum: valid signatures from >= k registry-verified DISTINCT custodians
  def check_11_quorum(ctx, %{effect: e, cert: c}, _view) do
    distinct =
      verify_all(ctx, c)
      |> Enum.flat_map(fn
        {_s, {:valid, %{custodian_id: cust}}} -> [cust]
        _ -> []
      end)
      |> Enum.uniq()
      |> length()

    if distinct >= Context.quorum_for(ctx, e.consequence_class),
      do: :ok,
      else: {:error, :quorum_not_met}
  end

  # 12 -- validity window with skew: not_before tolerates the actuator clock being up to
  # `skew` behind the authority; expiry never extends (RFC-007 E-K); TTL is capped.
  def check_12_validity_window(ctx, %{cert: c}, _view) do
    now = Context.now(ctx)

    cond do
      c.expires <= c.not_before -> {:error, :malformed_window}
      c.expires - c.not_before > ctx.max_ttl -> {:error, :ttl_too_long}
      now + ctx.skew < c.not_before -> {:error, :not_yet_valid}
      now >= c.expires -> {:error, :expired}
      true -> :ok
    end
  end

  # 13 -- revocation state: view present, fresh (<= max staleness), certificate epoch not
  # older than the view's, and no signer revoked in the actuator's own view.
  def check_13_revocation(ctx, %{cert: c}, _view) do
    now = Context.now(ctx)

    case ctx.revocation do
      %{refreshed_at: at, epoch: ep, revoked: revoked} ->
        cond do
          now - at > ctx.max_revocation_staleness -> {:error, :revocation_view_stale}
          at > now + ctx.skew -> {:error, :revocation_view_stale}
          c.revocation_epoch < ep -> {:error, :revocation_epoch_stale}
          Enum.any?(c.signatures, &MapSet.member?(revoked, &1.kid)) -> {:error, :key_revoked}
          true -> :ok
        end

      _ ->
        {:error, :revocation_view_missing}
    end
  end

  # 14 -- claim ownership (durable): no live/unresolved claim on the instance, and none of
  # the certificate's (kid, nonce) pairs already bound to a DIFFERENT instance.
  def check_14_claim_ownership(_ctx, %{effect: e, cert: c}, view) do
    foreign =
      Enum.any?(c.signatures, fn s ->
        case Map.get(view.nonce_owner || %{}, {s.kid, s.nonce}) do
          nil -> false
          owner -> owner != e.effect_instance_id
        end
      end)

    cond do
      foreign -> {:error, :nonce_replayed}
      is_nil(view.record) -> :ok
      view.record.state == :executing -> {:error, :claim_held}
      view.record.state == :unknown_outcome -> {:error, :unknown_outcome}
      view.record.state == :reconciled_not_performed -> {:error, :claim_closed}
      true -> :ok
    end
  end

  # 15 -- an instance that completed never runs again (replay returns evidence upstream)
  def check_15_not_completed(_ctx, _req, %{record: %{state: :completed}}),
    do: {:error, :effect_already_completed}

  def check_15_not_completed(_ctx, _req, _view), do: :ok

  # 16 -- generation is current: EQUALITY with the durable claim's generation, else with the
  # actuator's generation view for a fresh instance. Never >=.
  def check_16_generation(ctx, %{effect: e, cert: c}, view) do
    expected =
      case view.record do
        %{generation: g} -> g
        _ -> Map.get(ctx.generations, e.effect_instance_id, ctx.generation_default)
      end

    if c.generation == expected, do: :ok, else: {:error, :generation_stale}
  end

  # -- signature verification through the crypto boundary -------------------

  defp verify_all(ctx, c) do
    now = Context.now(ctx)
    clamped = now |> max(c.not_before) |> min(c.expires - 1)

    opts =
      [now: clamped, audience: ctx.audience, required_profile: ctx.required_profile] ++
        if(ctx.allowed_algs, do: [allowed_algs: ctx.allowed_algs], else: [])

    for sig <- c.signatures do
      standing =
        case Certificate.signed_message(c, sig) do
          {:ok, bytes} ->
            Sa2aCrypto.verify_envelope(
              Certificate.envelope(c, sig, bytes),
              bytes,
              ctx.registry,
              opts
            )

          {:error, _} ->
            {:invalid, :malformed_message}
        end

      {sig, standing}
    end
  end
end
