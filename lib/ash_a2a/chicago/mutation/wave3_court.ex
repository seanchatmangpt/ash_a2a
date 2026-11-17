# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Chicago.Mutation.Wave3Court do
  @moduledoc """
  Reference killer court `CHI-MUTWAVE3` for the wave-3 mutation catalog
  entries (`AshA2A.Chicago.Mutation.Catalog`): the email gateway plug gates,
  `AshA2A.Email.Dkim` refusals, the token ledger's insert-if-absent
  consumption, the single error-status table, the admission-refusal
  classifier, the JSON depth cap and decoder totality, the event journal
  writer, the control-plane TLS transport, `AgentCardSignature.verify/3` and
  the task owner gate.

  Every probe drives the REAL function or plug of this subject with real
  collaborators (real RSA/Ed25519 keys and signed messages, a real `:ssl`
  listener, a real EKV-backed ledger, a real ETS journal, `Plug.Test`
  connections through the real `AshA2A.Email.Plug`). A negative falsifier
  attacks one guard and its forbidden outcome is that the guard's own typed
  refusal is ABSENT (`outcome=absent`); a positive control proves the lawful
  path still works (`outcome=held`), so a mutant that merely breaks the
  subject cannot be mistaken for a guard removal.

  Non-discoverable, like `CHI-MUTGUARD`: it is a killer for catalog mutants,
  not a gate-numbered qualification court. The probe verdict is recorded as
  an `[:ash_a2a, :chicago, :wave3, :probe]` event inside the stimulus window,
  so the independent OCEL consumer corroborates every result.
  """

  use AshA2A.Chicago.Court, discoverable: false

  alias AshA2A.Chicago.{Context, Falsifier, Result}
  alias AshA2A.Chicago.Ocel.Mapping

  @id "CHI-MUTWAVE3"
  @event [:ash_a2a, :chicago, :wave3, :probe]
  @activity "mutwave3.probe"
  @now 1_800_000_000
  @sendgrid_secret "0123456789abcdef-secret"

  @impl true
  def id, do: @id
  @impl true
  def title,
    do: "Wave-3 mutation reference guards (email, DKIM, ledger, tables, TLS, card, owner)"

  @impl true
  def gate, do: nil
  @impl true
  def profile, do: :core
  @impl true
  def rfc_sections, do: ["§22", "§97", "§100"]

  @impl true
  def ocel_mappings do
    [
      Mapping.new!(
        event: @event,
        activity: @activity,
        source: __MODULE__,
        objects: fn _m, meta -> [{"wave3_probe", meta[:probe], "probe"}] end,
        attributes: fn _m, meta ->
          %{
            "probe" => meta[:probe],
            "outcome" => meta[:outcome],
            "detail" => meta[:detail] |> to_string() |> String.slice(0, 160)
          }
        end
      )
    ]
  end

  # {number, kind, probe, guard, invariant}
  @probes [
    {"001", :negative, :email_webhook_required, "Email.Plug.require_config/1 :webhook",
     "a request is refused 503 webhook_auth_unconfigured when no :webhook authentication is configured"},
    {"002", :negative, :email_replay_ledger_required, "Email.Plug.require_config/1 :token_ledger",
     "a request is refused 503 replay_protection_unconfigured when no :token_ledger is configured"},
    {"003", :negative, :email_webhook_authenticated, "Email.Plug.webhook_auth/3",
     "a request without the provider's webhook secret is refused 401 webhook_unauthorized"},
    {"004", :negative, :email_depth_cap, "Email.Plug.walk/3 depth cap",
     "a body nested deeper than 8 levels is refused 413 payload_too_complex"},
    {"005", :negative, :email_node_cap, "Email.Plug.walk/3 node cap",
     "a body of more than 2000 nodes is refused 413 payload_too_complex"},
    {"006", :negative, :email_reply_cap, "Email.Plug.reply_cap/2",
     "a reply longer than :max_reply_chars is refused 413 payload_too_large"},
    {"007", :negative, :dkim_body_length_limit, "Dkim.check_tags/1 l= tag",
     "a validly signed message carrying an l= truncation tag is refused :body_length_limit"},
    {"008", :negative, :dkim_multiple_from, "Dkim.from_domain/1 duplicate From",
     "a message with two From headers is refused :multiple_from even if the signed one is aligned"},
    {"009", :negative, :dkim_from_misaligned, "Dkim.alignment/3",
     "a From domain that is not the d= domain is refused :from_misaligned"},
    {"010", :negative, :dkim_expired, "Dkim.check_times/2 x=",
     "a signature whose x= is in the past is refused :expired"},
    {"011", :negative, :dkim_weak_key, "Dkim.check_size/1",
     "a 512-bit RSA key that verifies the signature is refused :weak_key"},
    {"012", :negative, :dkim_body_hash, "Dkim.check_body_hash/2",
     "a message whose body was altered after signing is refused :body_hash_mismatch"},
    {"013", :negative, :ledger_single_use, "TokenLedgerStore.do_reserve/4 insert-if-absent",
     "an already consumed (brief, n, token) is refused :already_consumed under another message id"},
    {"014", :negative, :error_bindings_table, "JSONRPC.Error.bindings/1 status table",
     "bindings(:all) carries every specification 5.4 row and the standard JSON-RPC rows"},
    {"015", :negative, :error_bindings_a2a_scope, "JSONRPC.Error.bindings/1 :a2a scope",
     "bindings(:a2a) holds exactly -32001..-32010"},
    {"016", :negative, :admission_refusal_classified, "Transport.Runtime.admission_refusal?/1",
     "an admission refusal is classified as a refusal (REJECTED), not a failure"},
    {"017", :negative, :admission_failure_not_refusal,
     "Transport.Runtime.admission_refusal?/1 fallback",
     "an execution failure is never classified as an admission refusal (FAILED stays FAILED)"},
    {"018", :negative, :json_guard_depth, "JSONGuard.within_depth?/2",
     "a body nested deeper than the cap is refused {:nesting_exceeded, max}"},
    {"019", :negative, :json_decode_totality, "Protocol.JSON.decode/2 non-map clause",
     "a non-object payload is a typed {:error, {:invalid_field, type}}, never a raise"},
    {"020", :negative, :journal_record_task, "EventJournal.record_task/3 append",
     "a task write is journaled: its events are replayable from the journal"},
    {"021", :negative, :journal_read_back, "EventJournalEts.append/4 read-back",
     "append returns :ok only when the event is readable from the journal"},
    {"022", :negative, :tls_verify_peer, "L07Tls.Transport.tls_options/1 verify: :verify_peer",
     "a server certificate from an unpinned CA is refused {:tls_refused, _}"},
    {"023", :negative, :tls_no_downgrade, "L07Tls.Transport.connect/4",
     "with :c2_tls configured the client never falls back to the unix socket"},
    {"024", :negative, :card_alg_none, "AgentCardSignature.check_alg/2 alg none",
     "an entry with alg none is refused {:alg_not_allowed, \"none\"}"},
    {"025", :negative, :card_alg_allowlist, "AgentCardSignature.check_alg/2 :allowed_algs",
     "a valid EdDSA entry is refused when :allowed_algs excludes EdDSA"},
    {"026", :negative, :card_alg_key_mismatch, "AgentCardSignature.check_key_alg/2",
     "an entry whose alg does not fit the key type is refused :alg_key_mismatch"},
    {"027", :negative, :card_tamper, "AgentCardSignature.raw_verify/4",
     "a card altered after signing is refused :bad_signature"},
    {"028", :negative, :owner_gate, "Transport.Runtime.owned_by?/2",
     "a task is invisible to a principal other than its owner"},
    {"101", :positive_control, :email_gates_pass, "Email.Plug gates",
     "a correctly configured, authenticated, bounded request passes the config, webhook and cap gates"},
    {"102", :positive_control, :dkim_valid, "Dkim.verify/2",
     "a valid relaxed/relaxed rsa-sha256 signature from an aligned domain verifies"},
    {"103", :positive_control, :ledger_first_use, "TokenLedgerStore.reserve/4",
     "the first use of a token is consumed and a distinct token is still spendable"},
    {"104", :positive_control, :tls_pinned_connects, "L07Tls.Transport.connect/4",
     "mutual TLS to a server certified by the pinned CA connects"},
    {"105", :positive_control, :card_valid, "AgentCardSignature.verify/3",
     "an untampered EdDSA-signed card verifies"},
    {"106", :positive_control, :owner_self, "Transport.Runtime.owned_by?/2",
     "a task is visible to its owner"},
    {"107", :positive_control, :json_total_ok, "JSONGuard.decode/2 + Protocol.JSON.decode/2",
     "a shallow body decodes and a well-formed task map decodes"}
  ]

  @doc "Probe names in falsifier order."
  @spec probes() :: [atom()]
  def probes, do: Enum.map(@probes, fn {_n, _k, name, _g, _i} -> name end)

  @impl true
  def falsifiers do
    for {n, kind, name, guard, invariant} <- @probes do
      fid = "#{@id}-#{n}"
      attempt = {:observed, @activity, %{"probe" => Atom.to_string(name)}}

      held_or_absent = fn outcome ->
        {:observed, @activity, %{"probe" => Atom.to_string(name), "outcome" => outcome}}
      end

      case kind do
        :negative ->
          Falsifier.new!(
            id: fid,
            court_id: @id,
            kind: :negative,
            invariant: invariant,
            stimulus: "real #{guard} probe `#{name}` (see #{inspect(__MODULE__)})",
            boundary: guard,
            forbidden_outcome: "the guard's own typed refusal is absent (outcome=absent)",
            attempt_evidence: "mutwave3.probe for #{name}",
            survival_evidence: "mutwave3.probe for #{name} with outcome=absent",
            guard: guard,
            failure_class: :meta_admission_failure,
            attempt_predicate: attempt,
            outcome_predicate: held_or_absent.("absent"),
            rfc_sections: ["§22", "§97"]
          )

        :positive_control ->
          Falsifier.new!(
            id: fid,
            court_id: @id,
            kind: :positive_control,
            invariant: invariant,
            stimulus: "real #{guard} lawful probe `#{name}`",
            boundary: guard,
            attempt_evidence: "mutwave3.probe for #{name}",
            survival_evidence: "mutwave3.probe for #{name} with outcome=held",
            attempt_predicate: attempt,
            outcome_predicate: held_or_absent.("held"),
            rfc_sections: ["§100"]
          )
      end
    end
  end

  @impl true
  def run(%Context{} = ctx) do
    fx = fixtures()

    for {f, {_n, kind, name, _g, _i}} <- Enum.zip(falsifiers(), @probes) do
      {outcome, detail} =
        Context.stimulus(ctx, f, fn ->
          {outcome, detail} = safe_probe(name, fx)

          :telemetry.execute(@event, %{count: 1}, %{
            probe: Atom.to_string(name),
            outcome: Atom.to_string(outcome),
            detail: detail
          })

          {outcome, detail}
        end)

      evidence = %{
        "probe" => Atom.to_string(name),
        "outcome" => Atom.to_string(outcome),
        "detail" => detail
      }

      result =
        case kind do
          :negative ->
            Result.negative(f,
              attempt_observed?: Context.observed?(ctx, f, @activity),
              forbidden_outcome_observed?: outcome == :absent
            )

          :positive_control ->
            Result.positive(f,
              attempt_observed?: Context.observed?(ctx, f, @activity),
              expected_outcome_observed?: outcome == :held
            )
        end

      %{result | evidence: evidence}
    end
  end

  # Explicit dispatch (no dynamic apply).
  defp probe(:email_webhook_required, fx), do: p_email_webhook_required(fx)
  defp probe(:email_replay_ledger_required, fx), do: p_email_replay_ledger_required(fx)
  defp probe(:email_webhook_authenticated, fx), do: p_email_webhook_authenticated(fx)
  defp probe(:email_depth_cap, fx), do: p_email_depth_cap(fx)
  defp probe(:email_node_cap, fx), do: p_email_node_cap(fx)
  defp probe(:email_reply_cap, fx), do: p_email_reply_cap(fx)
  defp probe(:email_gates_pass, fx), do: p_email_gates_pass(fx)
  defp probe(:dkim_body_length_limit, fx), do: p_dkim_body_length_limit(fx)
  defp probe(:dkim_multiple_from, fx), do: p_dkim_multiple_from(fx)
  defp probe(:dkim_from_misaligned, fx), do: p_dkim_from_misaligned(fx)
  defp probe(:dkim_expired, fx), do: p_dkim_expired(fx)
  defp probe(:dkim_weak_key, fx), do: p_dkim_weak_key(fx)
  defp probe(:dkim_body_hash, fx), do: p_dkim_body_hash(fx)
  defp probe(:dkim_valid, fx), do: p_dkim_valid(fx)
  defp probe(:ledger_single_use, fx), do: p_ledger_single_use(fx)
  defp probe(:ledger_first_use, fx), do: p_ledger_first_use(fx)
  defp probe(:error_bindings_table, fx), do: p_error_bindings_table(fx)
  defp probe(:error_bindings_a2a_scope, fx), do: p_error_bindings_a2a_scope(fx)
  defp probe(:admission_refusal_classified, fx), do: p_admission_refusal_classified(fx)
  defp probe(:admission_failure_not_refusal, fx), do: p_admission_failure_not_refusal(fx)
  defp probe(:json_guard_depth, fx), do: p_json_guard_depth(fx)
  defp probe(:json_decode_totality, fx), do: p_json_decode_totality(fx)
  defp probe(:json_total_ok, fx), do: p_json_total_ok(fx)
  defp probe(:journal_record_task, fx), do: p_journal_record_task(fx)
  defp probe(:journal_read_back, fx), do: p_journal_read_back(fx)
  defp probe(:tls_verify_peer, fx), do: p_tls_verify_peer(fx)
  defp probe(:tls_pinned_connects, fx), do: p_tls_pinned_connects(fx)
  defp probe(:tls_no_downgrade, fx), do: p_tls_no_downgrade(fx)
  defp probe(:card_alg_none, fx), do: p_card_alg_none(fx)
  defp probe(:card_alg_allowlist, fx), do: p_card_alg_allowlist(fx)
  defp probe(:card_alg_key_mismatch, fx), do: p_card_alg_key_mismatch(fx)
  defp probe(:card_tamper, fx), do: p_card_tamper(fx)
  defp probe(:card_valid, fx), do: p_card_valid(fx)
  defp probe(:owner_gate, fx), do: p_owner_gate(fx)
  defp probe(:owner_self, fx), do: p_owner_self(fx)

  defp safe_probe(name, fx) do
    probe(name, fx)
  rescue
    e ->
      {:absent,
       "raised #{inspect(e.__struct__)}: #{Exception.message(e) |> String.slice(0, 100)}"}
  catch
    kind, reason -> {:absent, "#{kind}: #{inspect(reason, limit: 4)}"}
  end

  defp verdict(true, detail), do: {:held, detail}
  defp verdict(false, detail), do: {:absent, detail}

  # --- fixtures -------------------------------------------------------------------

  defp fixtures do
    {:RSAPrivateKey, _, n, e, _, _, _, _, _, _, _} =
      priv = :public_key.generate_key({:rsa, 2048, 65_537})

    {:RSAPrivateKey, _, wn, we, _, _, _, _, _, _, _} =
      weak = :public_key.generate_key({:rsa, 512, 65_537})

    {pub, ed_priv} = :crypto.generate_key(:eddsa, :ed25519)

    %{
      rsa: priv,
      rsa_p: spki_b64({:RSAPublicKey, n, e}),
      weak: weak,
      weak_p: spki_b64({:RSAPublicKey, wn, we}),
      ed_jwk: %{
        "kty" => "OKP",
        "crv" => "Ed25519",
        "x" => Base.url_encode64(pub, padding: false),
        "d" => Base.url_encode64(ed_priv, padding: false),
        "kid" => "w3-key"
      }
    }
  end

  defp spki_b64(pub) do
    {:SubjectPublicKeyInfo, der, :not_encrypted} =
      :public_key.pem_entry_encode(:SubjectPublicKeyInfo, pub)

    Base.encode64(der)
  end

  # --- email plug probes ------------------------------------------------------------

  defp email_params(extra \\ %{}) do
    Map.merge(
      %{
        "from" => "approver@example.test",
        "in_reply_to" => "brief-1",
        "text" => "Approve 1.",
        "subject" => "Re: brief",
        "auth_results" => %{"dkim" => "pass", "spf" => "pass", "dmarc" => "pass"},
        "reply_tokens" => %{"1" => "tok"}
      },
      extra
    )
  end

  defp email_call(params, opts) do
    base = [
      policy: %{allowlist: %{}},
      brief_lookup: fn _ -> :error end,
      dispatch: fn _principal, _action -> {:error, :unused} end
    ]

    conn =
      Plug.Test.conn(:post, "/v1/email:ingest", params)
      |> AshA2A.Email.Plug.call(AshA2A.Email.Plug.init(Keyword.merge(base, opts)))

    error =
      case Jason.decode(conn.resp_body) do
        {:ok, %{"error" => e}} -> e
        _ -> nil
      end

    {conn.status, error}
  end

  defp email_expect(result, expected),
    do:
      verdict(
        result == expected,
        "plug answered #{inspect(result)}, guard answers #{inspect(expected)}"
      )

  defp p_email_webhook_required(_fx),
    do:
      email_call(email_params(), unsafe_no_replay_ledger: true)
      |> email_expect({503, "webhook_auth_unconfigured"})

  defp p_email_replay_ledger_required(_fx),
    do:
      email_call(email_params(), webhook: :trusted_ingress)
      |> email_expect({503, "replay_protection_unconfigured"})

  defp p_email_webhook_authenticated(_fx),
    do:
      email_call(email_params(),
        webhook: {:sendgrid, [secret: @sendgrid_secret]},
        unsafe_no_replay_ledger: true
      )
      |> email_expect({401, "webhook_unauthorized"})

  defp p_email_depth_cap(_fx) do
    deep = Enum.reduce(1..12, "x", fn _, acc -> %{"n" => acc} end)

    email_call(email_params(%{"deep" => deep}),
      webhook: :trusted_ingress,
      unsafe_no_replay_ledger: true
    )
    |> email_expect({413, "payload_too_complex"})
  end

  defp p_email_node_cap(_fx) do
    email_call(email_params(%{"pad" => Enum.to_list(1..2_500)}),
      webhook: :trusted_ingress,
      unsafe_no_replay_ledger: true
    )
    |> email_expect({413, "payload_too_complex"})
  end

  defp p_email_reply_cap(_fx) do
    email_call(email_params(%{"text" => String.duplicate("a", 64)}),
      webhook: :trusted_ingress,
      unsafe_no_replay_ledger: true,
      max_reply_chars: 16
    )
    |> email_expect({413, "payload_too_large"})
  end

  defp p_email_gates_pass(_fx) do
    {status, error} =
      email_call(email_params(), webhook: :trusted_ingress, unsafe_no_replay_ledger: true)

    verdict(
      status not in [503, 413] and error != "webhook_unauthorized",
      "answered #{inspect({status, error})}"
    )
  end

  # --- DKIM probes --------------------------------------------------------------------

  defp dkim_resolver(p) do
    fn
      "example.com", "sel" -> {:ok, p}
      _, _ -> {:error, :nxdomain}
    end
  end

  defp dkim_opts(p), do: [key_resolver: dkim_resolver(p), now: fn -> @now end]

  defp dkim_headers(from \\ " Alice <alice@example.com>") do
    [{"From", from}, {"To", " bob@example.org"}, {"Subject", " Hello   there"}]
  end

  @dkim_body "Approve 1.\r\n  trailing   spaces \r\n\r\n"

  defp canon_body(body) do
    lines =
      body
      |> String.split("\r\n")
      |> Enum.map(&(&1 |> String.replace(~r/[ \t]+/, " ") |> String.trim_trailing()))
      |> Enum.reverse()
      |> Enum.drop_while(&(&1 == ""))
      |> Enum.reverse()

    if lines == [], do: "", else: Enum.join(lines, "\r\n") <> "\r\n"
  end

  defp canon_hdr({n, v}),
    do: String.downcase(n) <> ":" <> (v |> String.replace(~r/[ \t]+/, " ") |> String.trim())

  # Independent signer: signs the bottom-most instance of each h= header.
  defp dkim_sign(priv, headers, body, tags \\ "") do
    h = ["from", "to", "subject"]
    bh = :crypto.hash(:sha256, canon_body(body)) |> Base.encode64()

    value =
      "v=1; a=rsa-sha256; c=relaxed/relaxed; d=example.com; s=sel; h=#{Enum.join(h, ":")}; bh=#{bh};#{tags} b="

    signed =
      Enum.map(h, fn name ->
        headers |> Enum.reverse() |> Enum.find(fn {n, _} -> String.downcase(n) == name end)
      end)
      |> Enum.reject(&is_nil/1)

    data =
      Enum.map_join(signed, &(canon_hdr(&1) <> "\r\n")) <> canon_hdr({"DKIM-Signature", value})

    sig = :public_key.sign(data, :sha256, priv) |> Base.encode64()

    folded =
      sig |> String.graphemes() |> Enum.chunk_every(60) |> Enum.map_join("\r\n\t", &Enum.join/1)

    all = [{"DKIM-Signature", " " <> value <> folded}] ++ headers
    Enum.map_join(all, &"#{elem(&1, 0)}:#{elem(&1, 1)}\r\n") <> "\r\n" <> body
  end

  defp dkim_expect(result, expected),
    do:
      verdict(
        result == expected,
        "Dkim.verify answered #{inspect(result)}, guard answers #{inspect(expected)}"
      )

  defp p_dkim_body_length_limit(fx),
    do:
      dkim_sign(fx.rsa, dkim_headers(), @dkim_body, " l=5;")
      |> AshA2A.Email.Dkim.verify(dkim_opts(fx.rsa_p))
      |> dkim_expect({:error, :body_length_limit})

  defp p_dkim_multiple_from(fx) do
    # The spoofed From sits ABOVE the signed (bottom-most) one, so the signature verifies.
    headers = [{"From", " Mallory <mallory@example.com>"} | dkim_headers()]

    dkim_sign(fx.rsa, headers, @dkim_body)
    |> AshA2A.Email.Dkim.verify(dkim_opts(fx.rsa_p))
    |> dkim_expect({:error, :multiple_from})
  end

  defp p_dkim_from_misaligned(fx),
    do:
      dkim_sign(fx.rsa, dkim_headers(" Alice <alice@evil.test>"), @dkim_body)
      |> AshA2A.Email.Dkim.verify(dkim_opts(fx.rsa_p))
      |> dkim_expect({:error, :from_misaligned})

  defp p_dkim_expired(fx),
    do:
      dkim_sign(fx.rsa, dkim_headers(), @dkim_body, " x=#{@now - 10};")
      |> AshA2A.Email.Dkim.verify(dkim_opts(fx.rsa_p))
      |> dkim_expect({:error, :expired})

  defp p_dkim_weak_key(fx),
    do:
      dkim_sign(fx.weak, dkim_headers(), @dkim_body)
      |> AshA2A.Email.Dkim.verify(dkim_opts(fx.weak_p))
      |> dkim_expect({:error, :weak_key})

  defp p_dkim_body_hash(fx),
    do:
      dkim_sign(fx.rsa, dkim_headers(), @dkim_body)
      |> String.replace("Approve 1.", "Approve 9.")
      |> AshA2A.Email.Dkim.verify(dkim_opts(fx.rsa_p))
      |> dkim_expect({:error, :body_hash_mismatch})

  defp p_dkim_valid(fx),
    do:
      dkim_sign(fx.rsa, dkim_headers(), @dkim_body)
      |> AshA2A.Email.Dkim.verify(dkim_opts(fx.rsa_p))
      |> dkim_expect(:ok)

  # --- token ledger probes ---------------------------------------------------------------

  defp with_ledger(fun) do
    n = System.unique_integer([:positive])
    dir = Path.join(System.tmp_dir!(), "w3_ledger_#{n}")
    kv = :"w3_kv_#{n}"
    ledger = :"w3_ledger_#{n}"
    File.rm_rf!(dir)

    {:ok, sup} =
      Supervisor.start_link(
        [
          AshA2A.TaskStore.Ekv.child_spec(name: kv, data_dir: dir),
          {AshA2A.Email.TokenLedgerStore, [store: kv, name: ledger]}
        ],
        strategy: :one_for_one
      )

    try do
      fun.(ledger)
    after
      Process.unlink(sup)
      Supervisor.stop(sup)
      File.rm_rf!(dir)
    end
  end

  defp p_ledger_single_use(_fx) do
    with_ledger(fn l ->
      first = AshA2A.Email.TokenLedgerStore.reserve(l, "b1", [{1, "t1"}], "m1")
      second = AshA2A.Email.TokenLedgerStore.reserve(l, "b1", [{1, "t1"}], "m2")

      verdict(
        first == :ok and second == {:error, :already_consumed},
        "first #{inspect(first)}, second #{inspect(second)}"
      )
    end)
  end

  defp p_ledger_first_use(_fx) do
    with_ledger(fn l ->
      a = AshA2A.Email.TokenLedgerStore.reserve(l, "b1", [{1, "t1"}], "m1")
      b = AshA2A.Email.TokenLedgerStore.reserve(l, "b1", [{2, "t2"}], "m2")
      verdict(a == :ok and b == :ok, "#{inspect(a)} #{inspect(b)}")
    end)
  end

  # --- tables and classifiers ---------------------------------------------------------------

  # Independent copy of specification section 5.4 plus the standard JSON-RPC rows.
  @spec_bindings %{
    -32_001 => {404, 5, "NOT_FOUND"},
    -32_002 => {400, 9, "FAILED_PRECONDITION"},
    -32_003 => {400, 9, "FAILED_PRECONDITION"},
    -32_004 => {400, 9, "FAILED_PRECONDITION"},
    -32_005 => {400, 3, "INVALID_ARGUMENT"},
    -32_006 => {500, 13, "INTERNAL"},
    -32_007 => {400, 9, "FAILED_PRECONDITION"},
    -32_008 => {400, 9, "FAILED_PRECONDITION"},
    -32_009 => {400, 9, "FAILED_PRECONDITION"},
    -32_010 => {409, 10, "ABORTED"},
    -32_700 => {400, 3, "INVALID_ARGUMENT"},
    -32_600 => {400, 3, "INVALID_ARGUMENT"},
    -32_601 => {400, 12, "UNIMPLEMENTED"},
    -32_602 => {400, 3, "INVALID_ARGUMENT"},
    -32_603 => {500, 13, "INTERNAL"},
    -32_000 => {503, 14, "UNAVAILABLE"}
  }

  defp p_error_bindings_table(_fx) do
    got = AshA2A.Protocol.JSONRPC.Error.bindings(:all)

    verdict(
      got == @spec_bindings,
      "bindings(:all) has #{map_size(got)} rows, spec has #{map_size(@spec_bindings)}"
    )
  end

  defp p_error_bindings_a2a_scope(_fx) do
    got = AshA2A.Protocol.JSONRPC.Error.bindings(:a2a)
    expected = Map.take(@spec_bindings, Enum.to_list(-32_010..-32_001//1))
    verdict(got == expected, "bindings(:a2a) has #{map_size(got)} rows, expected 10 A2A rows")
  end

  @refusals [
    :forbidden,
    {:forbidden, :x},
    "forbidden: nope",
    :skill_not_found,
    {:no_skill, "s"},
    {:unknown_skill, "s"},
    {:ambiguous_skill, "s"},
    {:skill_lookup, :forbidden},
    %{code: :authority_required}
  ]

  @failures [:boom, {:error, :timeout}, "kaput", %{code: :internal_error}, nil]

  defp p_admission_refusal_classified(_fx) do
    bad = Enum.reject(@refusals, &AshA2A.Transport.Runtime.admission_refusal?/1)
    verdict(bad == [], "refusals not classified as refusals: #{inspect(bad)}")
  end

  defp p_admission_failure_not_refusal(_fx) do
    bad = Enum.filter(@failures, &AshA2A.Transport.Runtime.admission_refusal?/1)
    verdict(bad == [], "failures classified as refusals: #{inspect(bad)}")
  end

  # --- JSON ---------------------------------------------------------------------------------

  defp p_json_guard_depth(_fx) do
    deep = String.duplicate("[", 200) <> String.duplicate("]", 200)
    got = AshA2A.Protocol.JSONGuard.decode(deep, 64)
    verdict(got == {:error, {:nesting_exceeded, 64}}, "decode answered #{inspect(got, limit: 3)}")
  end

  defp p_json_decode_totality(_fx) do
    got =
      for type <- [:task, :status, :message, :artifact, :part, :event],
          do: AshA2A.Protocol.JSON.decode("not an object", type)

    expected =
      for type <- [:task, :status, :message, :artifact, :part, :event],
          do: {:error, {:invalid_field, Atom.to_string(type)}}

    verdict(got == expected, "decode answered #{inspect(got, limit: 3)}")
  end

  defp p_json_total_ok(_fx) do
    shallow = AshA2A.Protocol.JSONGuard.decode(~s({"a":[1,2,{"b":null}]}), 64)

    {:ok, wire} =
      AshA2A.Protocol.JSON.encode(AshA2A.Protocol.Task.new(id: "w3-json", context_id: "ctx"))

    decoded = AshA2A.Protocol.JSON.decode(wire, :task)

    verdict(
      match?({:ok, %{"a" => _}}, shallow) and match?({:ok, %AshA2A.Protocol.Task{}}, decoded),
      "shallow #{inspect(shallow, limit: 3)}, task #{inspect(decoded, limit: 3)}"
    )
  end

  # --- event journal ------------------------------------------------------------------------

  defp with_journal(fun) do
    name = :"w3_journal_#{System.unique_integer([:positive])}"
    {:ok, pid} = AshA2A.TaskStore.EventJournalEts.start_link(name: name)

    try do
      fun.({AshA2A.TaskStore.EventJournalEts, name})
    after
      Process.unlink(pid)
      Agent.stop(pid)
    end
  end

  defp p_journal_record_task(_fx) do
    with_journal(fn journal ->
      task = AshA2A.Protocol.Task.new(id: "w3-journal-task", context_id: "ctx")
      :ok = AshA2A.Protocol.EventJournal.record_task(journal, nil, task)
      {:ok, events} = AshA2A.Protocol.EventJournal.replay_after(journal, task.id, 0)
      verdict(events != [], "#{length(events)} journaled events replayable")
    end)
  end

  defp p_journal_read_back(_fx) do
    with_journal(fn journal ->
      event = %{"statusUpdate" => %{"taskId" => "w3-journal-rb"}}
      appended = AshA2A.Protocol.EventJournal.append(journal, "w3-journal-rb", 3, event)
      {:ok, events} = AshA2A.Protocol.EventJournal.replay_after(journal, "w3-journal-rb", 0)
      stored? = event in events

      # `:ok` is only lawful when the event is readable; an honest failure is also lawful.
      verdict(
        (appended == :ok and stored?) or (appended != :ok and not stored?),
        "append answered #{inspect(appended)}, event readable: #{stored?}"
      )
    end)
  end

  # --- TLS ------------------------------------------------------------------------------------

  defp san(name),
    do: [{:Extension, {2, 5, 29, 17}, false, [{:dNSName, String.to_charlist(name)}]}]

  defp rsa_opts, do: [key: :public_key.generate_key({:rsa, 2048, 65_537})]

  defp pki do
    :public_key.pkix_test_data(%{
      server_chain: %{
        root: rsa_opts(),
        intermediates: [],
        peer: rsa_opts() ++ [extensions: san("localhost")]
      },
      client_chain: %{root: rsa_opts(), intermediates: [], peer: rsa_opts()}
    })
  end

  @tls_base [:binary, packet: 4, active: false]

  defp tls_server(%{server_config: sc}) do
    {:ok, _} = Application.ensure_all_started(:ssl)

    {:ok, l} =
      :ssl.listen(
        0,
        sc ++
          [:binary, packet: 4, active: false, reuseaddr: true] ++
          [verify: :verify_peer, fail_if_no_peer_cert: true]
      )

    {:ok, {_, port}} = :ssl.sockname(l)

    spawn(fn ->
      with {:ok, s} <- :ssl.transport_accept(l, 5_000),
           {:ok, s} <- :ssl.handshake(s, 5_000),
           {:ok, _} <- :ssl.recv(s, 0, 2_000) do
        :ssl.close(s)
      end
    end)

    {port, l}
  end

  defp tls_cfg(port, client_config, ca_from) do
    %{
      host: "localhost",
      port: port,
      cacerts: Keyword.fetch!(ca_from, :cacerts),
      cert: Keyword.fetch!(client_config, :cert),
      key: Keyword.fetch!(client_config, :key)
    }
  end

  defp tls_close({:ok, {:ssl, _} = conn}), do: AshA2A.C2.L07Tls.Transport.close(conn)
  defp tls_close({:ok, {:gen_tcp, _} = conn}), do: AshA2A.C2.L07Tls.Transport.close(conn)
  defp tls_close(_), do: :ok

  defp p_tls_verify_peer(_fx) do
    %{client_config: cc} = p = pki()
    %{client_config: other_cc} = pki()
    {port, l} = tls_server(p)

    try do
      # Valid client identity, but the pinned CA is another PKI's root: the server is untrusted.
      cfg = tls_cfg(port, cc, other_cc)
      got = AshA2A.C2.L07Tls.Transport.connect(nil, %{c2_tls: cfg}, @tls_base, 5_000)
      tls_close(got)

      verdict(
        match?({:error, {:tls_refused, _}}, got),
        "connect answered #{inspect(got, limit: 3)}"
      )
    after
      :ssl.close(l)
    end
  end

  defp p_tls_pinned_connects(_fx) do
    %{client_config: cc} = p = pki()
    {port, l} = tls_server(p)

    try do
      got =
        AshA2A.C2.L07Tls.Transport.connect(
          nil,
          %{c2_tls: tls_cfg(port, cc, cc)},
          @tls_base,
          5_000
        )

      tls_close(got)
      verdict(match?({:ok, {:ssl, _}}, got), "connect answered #{inspect(got, limit: 3)}")
    after
      :ssl.close(l)
    end
  end

  defp p_tls_no_downgrade(_fx) do
    %{client_config: cc} = pki()
    path = Path.join(System.tmp_dir!(), "w3_uds_#{System.unique_integer([:positive])}.sock")
    File.rm(path)

    {:ok, l} =
      :gen_tcp.listen(0, [:binary, active: false, ifaddr: {:local, String.to_charlist(path)}])

    try do
      # A reachable unix socket is supplied; a configured TLS endpoint (closed port) must not fall back to it.
      cfg = tls_cfg(1, cc, cc)
      got = AshA2A.C2.L07Tls.Transport.connect(path, %{c2_tls: cfg}, @tls_base, 1_000)
      tls_close(got)

      verdict(
        match?({:error, {:tls_refused, _}}, got),
        "connect answered #{inspect(got, limit: 3)}"
      )
    after
      :gen_tcp.close(l)
      File.rm(path)
    end
  end

  # --- agent card signature ---------------------------------------------------------------------

  defp card, do: %{"name" => "w3-agent", "url" => "https://w3.example/a2a", "version" => "1"}

  defp pub_jwks(jwk), do: %{"keys" => [Map.drop(jwk, ["d"])]}

  defp signed_card(fx) do
    {:ok, entry} = AshA2A.Protocol.AgentCardSignature.sign(card(), fx.ed_jwk, kid: "w3-key")
    AshA2A.Protocol.AgentCardSignature.attach(card(), [entry])
  end

  defp raw_entry(protected_map, signature) do
    protected = protected_map |> Jason.encode!() |> Base.url_encode64(padding: false)
    %{"protected" => protected, "signature" => signature}
  end

  defp p_card_alg_none(fx) do
    c =
      AshA2A.Protocol.AgentCardSignature.attach(card(), [
        raw_entry(%{"alg" => "none", "kid" => "w3-key"}, "")
      ])

    got = AshA2A.Protocol.AgentCardSignature.verify(c, pub_jwks(fx.ed_jwk))

    verdict(got == {:error, {:alg_not_allowed, "none"}}, "verify answered #{inspect(got)}")
  end

  defp p_card_alg_allowlist(fx) do
    got =
      AshA2A.Protocol.AgentCardSignature.verify(signed_card(fx), pub_jwks(fx.ed_jwk),
        allowed_algs: ["ES256"]
      )

    verdict(got == {:error, {:alg_not_allowed, "EdDSA"}}, "verify answered #{inspect(got)}")
  end

  defp p_card_alg_key_mismatch(fx) do
    # Ed25519 key, entry claiming ES256: a real signature over the entry's own signing input.
    protected = %{"alg" => "ES256", "kid" => "w3-key", "typ" => "JOSE"}
    p64 = protected |> Jason.encode!() |> Base.url_encode64(padding: false)
    {:ok, payload} = AshA2A.Wire.Jcs.encode(card())
    input = p64 <> "." <> Base.url_encode64(payload, padding: false)
    {:ok, d} = Base.url_decode64(fx.ed_jwk["d"], padding: false)
    sig = :crypto.sign(:eddsa, :none, input, [d, :ed25519]) |> Base.url_encode64(padding: false)

    c =
      AshA2A.Protocol.AgentCardSignature.attach(card(), [
        %{"protected" => p64, "signature" => sig}
      ])

    got = AshA2A.Protocol.AgentCardSignature.verify(c, pub_jwks(fx.ed_jwk))

    verdict(got == {:error, :alg_key_mismatch}, "verify answered #{inspect(got)}")
  end

  defp p_card_tamper(fx) do
    tampered = Map.put(signed_card(fx), "name", "w3-agent-evil")
    got = AshA2A.Protocol.AgentCardSignature.verify(tampered, pub_jwks(fx.ed_jwk))

    verdict(got == {:error, :bad_signature}, "verify answered #{inspect(got)}")
  end

  defp p_card_valid(fx) do
    got = AshA2A.Protocol.AgentCardSignature.verify(signed_card(fx), pub_jwks(fx.ed_jwk))
    verdict(got == {:ok, ["w3-key"]}, "verify answered #{inspect(got)}")
  end

  # --- owner gate ----------------------------------------------------------------------------------

  defp owned_task do
    AshA2A.Protocol.Task.new(
      id: "w3-owned",
      context_id: "ctx",
      metadata: %{AshA2A.Transport.Runtime.owner_key() => "alice"}
    )
  end

  defp p_owner_gate(_fx) do
    task = owned_task()

    leaks =
      Enum.filter(["mallory", {"mallory", nil}, {"alice", "other-tenant"}, :anonymous], fn who ->
        AshA2A.Transport.Runtime.owned_by?(task, who)
      end)

    verdict(leaks == [], "task visible to #{inspect(leaks)}")
  end

  defp p_owner_self(_fx) do
    task = owned_task()

    verdict(
      AshA2A.Transport.Runtime.owned_by?(task, "alice") and
        AshA2A.Transport.Runtime.owned_by?(task, {"alice", nil}),
      "owner sees own task"
    )
  end
end
