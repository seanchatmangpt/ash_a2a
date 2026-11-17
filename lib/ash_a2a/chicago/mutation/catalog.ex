# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Chicago.Mutation.Catalog do
  @moduledoc """
  RFC-SA2A-002 §97 security mutations mapped onto the real functions of this
  subject that enforce each guard.

  Every entry names an exact `Module.function/arity` (public or private),
  the clauses it replaces and the mutant body, plus the court-id families
  expected to kill it. Killer ids follow RFC-SA2A-002 Appendix B; a court
  that is not compiled in this subject leaves the entry `:blocked` (another
  qualification slice supplies it), and a target that does not resolve --
  e.g. a module not compiled in the subject, or a guard whose arity moved --
  is `:blocked` with the resolver's reason. Nothing is silently skipped.

  `CHI-MUTGUARD` (`AshA2A.Chicago.Fixtures.MutationHarness.GuardCourt`) is a
  non-discoverable reference court over the real `AshA2A.CommandBus`,
  `AshA2A.Authority` and `AshA2A.Authority.Broker.InMemory` so the harness has
  a real killer for the BRCE/authority guards in every subject.

  | § 97 mutation                          | target                                              |
  |----------------------------------------|-----------------------------------------------------|
  | return true from authority check       | `AshA2A.CommandBus.admit/2`, `AshA2A.Authority.admits?/2` |
  | ignore expiry                          | `AshA2A.Authority.expired?/1`                        |
  | ignore revocation                      | `AshA2A.Authority.Broker.InMemory.grant_status/2`    |
  | remove receipt preparation             | `AshA2A.CommandBus.prepare_receipt_anchor/4`         |
  | accept unsupported profile             | `AshA2A.Semantic.Envelope.validate_profile/1`        |
  | trust sender standing                  | `AshA2A.Semantic.Envelope.reject_declared_standing/1`|
  | skip SHACL                             | `AshA2A.Semantic.AdmissionPipeline.run_stage/4` (`:shacl`) |
  | skip graph-global falsifiers           | `AdmissionPipeline.run_stage/4` (`:sparql_falsifiers`), `AshA2A.Semantic.FalsifierSuite.do_admit/1` |
  | allow caller-controlled consequence    | `AshA2A.CommandBus.inspect_target/2`, `AshA2A.Authority.Decision.classify/1` |
  | allow root-manifest component drift    | `AshA2A.Semantic.RootManifest.verify_pins/1`         |
  | allow replay to call actuator          | `AshA2A.CommandBus.claim_receipt/3`                  |

  Court falsifier ids (`SA2A-MUTATION-NNN`) are bound to entry ids in
  `numbered/0`; entries are append-only so ids stay stable (§136).
  """

  alias AshA2A.Chicago.Mutation

  @guard_court "CHI-MUTGUARD"

  @doc "Non-discoverable reference courts the catalog may use as killers."
  @spec reference_courts() :: [module()]
  def reference_courts,
    do: [
      AshA2A.Chicago.Fixtures.MutationHarness.GuardCourt,
      AshA2A.Chicago.Mutation.Wave3Court
    ]

  @doc "Every §97 mutation, in court falsifier order."
  @spec entries() :: [Mutation.t()]
  def entries do
    [
      %Mutation{
        id: "authority_check_true",
        rfc_mutation: "return true from authority check",
        module: AshA2A.CommandBus,
        function: :admit,
        arity: 2,
        clauses: :all,
        operator: {:replace_body, "ok."},
        guard:
          "CommandBus.admit/2 (authority_required / authority_mismatch / consequence_unclassified)",
        killers: ["SA2A-AUTH", "CHI-BRCE", @guard_court]
      },
      %Mutation{
        id: "authority_admits_true",
        rfc_mutation: "return true from authority check (authority binding)",
        module: AshA2A.Authority,
        function: :admits?,
        arity: 2,
        clauses: :all,
        operator: {:replace_body, "true."},
        guard: "Authority.admits?/2 subject/capability/expiry binding",
        killers: ["SA2A-AUTH", @guard_court]
      },
      %Mutation{
        id: "ignore_expiry",
        rfc_mutation: "ignore expiry",
        module: AshA2A.Authority,
        function: :expired?,
        arity: 1,
        clauses: :all,
        operator: {:replace_body, "false."},
        guard: "Authority.expired?/1 real-clock time bound",
        killers: ["SA2A-AUTH", @guard_court]
      },
      # `grant_status/2` is where the revoked set is read: both the broker
      # lookup (`{:grant_status, key}`) and `standing?/2` go through it.
      %Mutation{
        id: "ignore_revocation",
        rfc_mutation: "ignore revocation",
        module: AshA2A.Authority.Broker.InMemory,
        function: :grant_status,
        arity: 2,
        clauses: :all,
        operator:
          {:replace_body,
           """
           case maps:find(ChicagoArg2, maps:get(issued, ChicagoArg1)) of
             {ok, ChicagoEntry} -> 'entry_status'(false, maps:get(expires_at, ChicagoEntry));
             error -> absent
           end.
           """},
        guard: "Broker.InMemory.grant_status/2 revoked-set membership",
        killers: ["SA2A-AUTH", @guard_court]
      },
      %Mutation{
        id: "remove_receipt_preparation",
        rfc_mutation: "remove receipt preparation",
        module: AshA2A.CommandBus,
        function: :prepare_receipt_anchor,
        arity: 4,
        clauses: :all,
        operator: {:replace_body, "{ok, nil}."},
        guard: "CommandBus.prepare_receipt_anchor/4 pending receipt anchor before DO",
        killers: ["CHI-BRCE", @guard_court]
      },
      %Mutation{
        id: "accept_unsupported_profile",
        rfc_mutation: "accept unsupported profile",
        module: AshA2A.Semantic.Envelope,
        function: :validate_profile,
        arity: 1,
        clauses: {:clause, 1},
        operator: {:replace_body, "ok."},
        guard: "Envelope.validate_profile/1 known-profile check (:unsupported_profile)",
        killers: ["SA2A-ENV"]
      },
      %Mutation{
        id: "trust_sender_standing",
        rfc_mutation: "trust sender standing",
        module: AshA2A.Semantic.Envelope,
        function: :reject_declared_standing,
        arity: 1,
        clauses: :all,
        operator: {:replace_body, "ok."},
        guard: "Envelope.reject_declared_standing/1 (:standing_self_declared)",
        killers: ["SA2A-ENV", "CHI-ADM"]
      },
      %Mutation{
        id: "skip_shacl",
        rfc_mutation: "skip SHACL",
        module: AshA2A.Semantic.AdmissionPipeline,
        function: :run_stage,
        arity: 4,
        clauses: {:arg_literal, 1, :shacl},
        operator: {:replace_body, "{ok, nil}."},
        guard: "AdmissionPipeline SHACL stage (:shacl_nonconformant / undetermined)",
        killers: ["SA2A-SHACL", "CHI-ADM"]
      },
      %Mutation{
        id: "skip_graph_global_falsifiers",
        rfc_mutation: "skip graph-global falsifiers",
        module: AshA2A.Semantic.AdmissionPipeline,
        function: :run_stage,
        arity: 4,
        clauses: {:arg_literal, 1, :sparql_falsifiers},
        operator: {:replace_body, "{ok, nil}."},
        guard: "AdmissionPipeline SPARQLFalsifiers stage (:falsifier_violated)",
        killers: ["SA2A-SPARQL", "CHI-ADM"]
      },
      # The gate's DECISION (`do_admit/1`), not `admit/1` itself: `admit/1` also
      # emits the boundary's §12 attempt evidence, and a mutant that deletes the
      # evidence emitter is judged UNKNOWN (attempt unobserved) by every court,
      # never killed -- that would test observability, not the gate.
      %Mutation{
        id: "skip_graph_global_falsifier_gate",
        rfc_mutation: "skip graph-global falsifiers (S18.2 admission gate)",
        module: AshA2A.Semantic.FalsifierSuite,
        function: :do_admit,
        arity: 1,
        clauses: :all,
        operator: {:replace_body, "ok."},
        guard:
          "FalsifierSuite.admit/1 mandatory falsifier gate decision do_admit/1 (:refused_falsifier)",
        killers: ["SA2A-SPARQL", "SA2A-LOGIC"]
      },
      %Mutation{
        id: "caller_controlled_consequence",
        rfc_mutation: "allow caller-controlled consequence class",
        module: AshA2A.CommandBus,
        function: :inspect_target,
        arity: 2,
        clauses: :all,
        operator:
          {:replace_body,
           """
           case 'Elixir.AshA2A.Info':skill(ChicagoArg2, maps:get(capability_id, ChicagoArg1)) of
             {ok, ChicagoSkill} ->
               {ok, ChicagoSkill,
                'Elixir.Ash.Resource.Info':action(maps:get(resource, ChicagoSkill), maps:get(action, ChicagoSkill)),
                maps:get(consequence, maps:get(metadata, ChicagoArg1), maps:get(consequence, ChicagoSkill))};
             {error, _} ->
               {error, \#{code => capability_not_found, detail => <<"capability_not_found">>}}
           end.
           """},
        guard: "CommandBus.inspect_target/2 consequence taken from the resource DSL",
        killers: ["SA2A-AUTH", "CHI-BRCE", @guard_court]
      },
      %Mutation{
        id: "caller_controlled_consequence_decision",
        rfc_mutation: "allow caller-controlled consequence class (portable decision)",
        module: AshA2A.Authority.Decision,
        function: :classify,
        arity: 1,
        clauses: :all,
        operator: {:replace_body, "{ok, maps:get(<<\"consequence\">>, ChicagoArg1, nil)}."},
        guard: "Authority.Decision.classify/1 (:consequence_unattested)",
        killers: ["SA2A-AUTH"]
      },
      %Mutation{
        id: "root_manifest_component_drift",
        rfc_mutation: "allow root-manifest component drift",
        module: AshA2A.Semantic.RootManifest,
        function: :verify_pins,
        arity: 1,
        clauses: :all,
        operator: {:replace_body, "ok."},
        guard: "RootManifest.verify_pins/1 (REFUSED_MANIFEST_DRIFT)",
        killers: ["SA2A-ROOT", "SA2A-MANIFEST", "CHI-ID"]
      },
      %Mutation{
        id: "replay_calls_actuator",
        rfc_mutation: "allow replay to call actuator",
        module: AshA2A.CommandBus,
        function: :claim_receipt,
        arity: 3,
        clauses: :all,
        operator:
          {:replace_body,
           """
           case ChicagoArg1:claim(ChicagoArg2, ChicagoArg3) of
             {replay, ChicagoReceipt} -> {execute, maps:get(execution_id, ChicagoReceipt)};
             ChicagoOther -> ChicagoOther
           end.
           """},
        # The mutant re-issues the committed receipt's OWN execution id, so it
        # also satisfies the RFC-SA2A-004 execution fence (`confirm_claim/3`
        # compares the stored claim's execution id); a freshly minted id would
        # be stopped by that fence and the mutation would prove the fence, not
        # the replay branch.
        guard: "CommandBus replay branch: a committed receipt is returned, never re-actuated",
        killers: ["CHI-REPLAY", "CHI-BRCE", @guard_court]
      },
      # v26.10.1-loop lane A1: the two-port graph-digest checkpoint. The
      # carried order graph_digest is pinned against the executing command's
      # semantic_subject.graph_digest; deleting the pin lets a re-pointed
      # semantic graph ride a still-valid work-order identity into claim
      # and DO (CHI-HILT-001/002 observe the forbidden admission).
      %Mutation{
        id: "hilt_graph_digest_ok",
        rfc_mutation: "carry without pinning (drop the two-port graph-digest checkpoint)",
        module: AshA2A.Hilt.WorkOrder,
        function: :checkpoint_graph_digest,
        arity: 2,
        clauses: :all,
        operator: {:replace_body, "ok."},
        guard:
          "Hilt.WorkOrder.checkpoint_graph_digest/2 two-port pin: the carried order " <>
            "graph_digest must equal the executing command's semantic_subject.graph_digest " <>
            "(both present and disagreeing -> refuse :stale_graph_identity; either absent -> skip)",
        killers: ["CHI-HILT"]
      },
      # v26.10.2 loops-of-loops lane L1: the algebraic two-port lease gate.
      # One entry per conjunct-bypass -- replacing any conjunct's verdict with
      # `false` (never failed) lets a tampered lease ride into claim and DO.
      # CHI-TWO-PORT's single-bit tamper falsifiers observe the forbidden
      # admission on each.
      %Mutation{
        id: "lease_scope_check_ok",
        rfc_mutation: "scope conjunct never fails (two-port lease gate)",
        module: AshA2A.Authority.TwoPortGate,
        function: :scope_failed?,
        arity: 2,
        clauses: :all,
        operator: {:replace_body, "false."},
        guard:
          "TwoPortGate scope_failed?/2 conjunct (a): the lease's scope_digest " <>
            "must equal H(scope_of(command)) or the mask carries 0x1 " <>
            "(:lease_scope_mismatch)",
        killers: ["CHI-TWO-PORT"]
      },
      %Mutation{
        id: "lease_root_check_ok",
        rfc_mutation: "root conjunct never fails (two-port lease gate)",
        module: AshA2A.Authority.TwoPortGate,
        function: :root_failed?,
        arity: 3,
        clauses: :all,
        operator: {:replace_body, "false."},
        guard:
          "TwoPortGate root_failed?/3 conjunct (b): the lease's root_digest must " <>
            "equal the command's RDFC-1.0 root (recomputed via CanonicalGraph when " <>
            "rdf_state is carried; opaque compare of the carried graph_digest " <>
            "otherwise) or the mask carries 0x2 (:lease_root_mismatch)",
        killers: ["CHI-TWO-PORT"]
      },
      %Mutation{
        id: "lease_clock_check_ok",
        rfc_mutation: "clock conjunct never fails (two-port lease gate)",
        module: AshA2A.Authority.TwoPortGate,
        function: :clock_failed?,
        arity: 3,
        clauses: :all,
        operator: {:replace_body, "false."},
        guard:
          "TwoPortGate clock_failed?/3 conjunct (c): the hybrid clock window " <>
            "(same-VM monotonic [T_start, T_exp]; cross-VM wall " <>
            "[not_before, expires_at]) must contain the captured clock or the " <>
            "mask carries 0x4 (:lease_expired)",
        killers: ["CHI-TWO-PORT"]
      },
      %Mutation{
        id: "lease_signature_check_ok",
        rfc_mutation: "signature conjunct never fails (two-port lease gate)",
        module: AshA2A.Authority.TwoPortGate,
        function: :signature_failed?,
        arity: 2,
        clauses: :all,
        operator: {:replace_body, "false."},
        guard:
          "TwoPortGate signature_failed?/2 conjunct (d): the lease's Ed25519 " <>
            "signature must verify under the authorizing authority's public key " <>
            "(fail closed on missing key or signature) or the mask carries 0x8 " <>
            "(:lease_signature_invalid)",
        killers: ["CHI-TWO-PORT"]
      }
    ] ++ wave3()
  end

  # Wave 3: the guards added after the original §97 catalog. Every entry is
  # killed by the reference court `CHI-MUTWAVE3`
  # (`AshA2A.Chicago.Mutation.Wave3Court`), whose probes drive the real
  # function, plug or transport with real collaborators. Bodies are Erlang
  # expressions over the aliased arguments `ChicagoArg1..N`.
  @wave3_killer "CHI-MUTWAVE3"

  defp wave3 do
    [
      # --- email gateway plug (lib/ash_a2a/email/plug.ex) -----------------------------------
      wave3(
        "email_webhook_auth_optional",
        "request authentication optional (email gateway)",
        AshA2A.Email.Plug,
        :require_config,
        1,
        :all,
        ~S"""
        ChicagoLedger = proplists:get_value(token_ledger, ChicagoArg1),
        ChicagoUnsafe = proplists:get_value(unsafe_no_replay_ledger, ChicagoArg1),
        case (ChicagoLedger =:= undefined orelse ChicagoLedger =:= nil) andalso ChicagoUnsafe =/= true of
          true -> {halt, 503, replay_protection_unconfigured};
          false -> ok
        end.
        """,
        "Email.Plug.require_config/1 :webhook required (503 webhook_auth_unconfigured); the replay-ledger refusal is kept"
      ),
      wave3(
        "email_replay_ledger_optional",
        "replay protection optional (email gateway)",
        AshA2A.Email.Plug,
        :require_config,
        1,
        :all,
        ~S"""
        case proplists:get_value(webhook, ChicagoArg1) of
          undefined -> {halt, 503, webhook_auth_unconfigured};
          nil -> {halt, 503, webhook_auth_unconfigured};
          false -> {halt, 503, webhook_auth_unconfigured};
          _ -> ok
        end.
        """,
        "Email.Plug.require_config/1 :token_ledger required (503 replay_protection_unconfigured); the webhook refusal is kept"
      ),
      wave3(
        "email_webhook_auth_skipped",
        "skip provider webhook authentication",
        AshA2A.Email.Plug,
        :webhook_auth,
        3,
        :all,
        "ok.",
        "Email.Plug.webhook_auth/3 provider authentication before any body field is trusted (401 webhook_unauthorized)"
      ),
      wave3(
        "email_depth_cap_ok",
        "no depth cap on the parsed body",
        AshA2A.Email.Plug,
        :walk,
        3,
        {:clause, 1},
        "{ok, ChicagoArg3}.",
        "Email.Plug.walk/3 depth cap (> 8 levels -> 413 payload_too_complex)"
      ),
      wave3(
        "email_node_cap_ok",
        "no node cap on the parsed body",
        AshA2A.Email.Plug,
        :walk,
        3,
        {:clause, 2},
        "{ok, ChicagoArg3}.",
        "Email.Plug.walk/3 node cap (> 2000 nodes -> 413 payload_too_complex)"
      ),
      wave3(
        "email_reply_cap_ok",
        "no cap on the reply size",
        AshA2A.Email.Plug,
        :reply_cap,
        2,
        :all,
        "ok.",
        "Email.Plug.reply_cap/2 reply size cap (413 payload_too_large)"
      ),
      # --- DKIM (lib/ash_a2a/email/dkim.ex) -------------------------------------------------
      wave3(
        "dkim_body_length_limit_ok",
        "accept a truncated body hash (DKIM l=)",
        AshA2A.Email.Dkim,
        :check_tags,
        1,
        :all,
        ~S"""
        ChicagoV = maps:get(<<"v">>, ChicagoArg1, undefined),
        ChicagoA = maps:get(<<"a">>, ChicagoArg1, undefined),
        ChicagoC = maps:get(<<"c">>, ChicagoArg1, undefined),
        ChicagoMissing = lists:any(fun(ChicagoK) -> maps:get(ChicagoK, ChicagoArg1, <<>>) =:= <<>> end, [<<"d">>, <<"s">>, <<"h">>, <<"bh">>, <<"b">>]),
        case {ChicagoV =/= <<"1">>, ChicagoA =/= <<"rsa-sha256">>, ChicagoC =/= <<"relaxed/relaxed">>} of
          {true, _, _} -> {error, unsupported_version};
          {_, true, _} -> {error, unsupported_algorithm};
          {_, _, true} -> {error, unsupported_canonicalization};
          _ -> case ChicagoMissing of true -> {error, malformed_signature}; false -> ok end
        end.
        """,
        "Dkim.check_tags/1 l= refusal (:body_length_limit); every other tag check is kept"
      ),
      wave3(
        "dkim_multiple_from_ok",
        "accept duplicate From headers (use the last)",
        AshA2A.Email.Dkim,
        :from_domain,
        1,
        :all,
        ~S"""
        case [ChicagoV || {ChicagoN, ChicagoV} <- ChicagoArg1, string:lowercase(ChicagoN) =:= <<"from">>] of
          [] -> {error, from_not_signed};
          ChicagoL ->
            case re:run(lists:last(ChicagoL), <<"@([A-Za-z0-9.-]+)">>, [global, {capture, all_but_first, binary}]) of
              nomatch -> {error, from_misaligned};
              {match, ChicagoM} -> {ok, string:lowercase(hd(lists:last(ChicagoM)))}
            end
        end.
        """,
        "Dkim.from_domain/1 exactly one From (:multiple_from)"
      ),
      wave3(
        "dkim_from_alignment_ok",
        "From domain need not align with d=",
        AshA2A.Email.Dkim,
        :alignment,
        3,
        :all,
        "ok.",
        "Dkim.alignment/3 From domain equals or is a subdomain of d= (:from_misaligned)"
      ),
      wave3(
        "dkim_expiry_ok",
        "ignore signature expiry (x=) and future timestamp",
        AshA2A.Email.Dkim,
        :check_times,
        2,
        :all,
        "ok.",
        "Dkim.check_times/2 x= expiry (:expired) and t= skew (:future_timestamp)"
      ),
      wave3(
        "dkim_weak_key_ok",
        "accept a weak RSA key",
        AshA2A.Email.Dkim,
        :check_size,
        1,
        {:clause, 1},
        "{ok, ChicagoArg1}.",
        "Dkim.check_size/1 minimum RSA modulus (:weak_key)"
      ),
      wave3(
        "dkim_body_hash_ok",
        "do not check the body hash",
        AshA2A.Email.Dkim,
        :check_body_hash,
        2,
        :all,
        "ok.",
        "Dkim.check_body_hash/2 bh= against the canonicalized body (:body_hash_mismatch)"
      ),
      # --- token ledger (lib/ash_a2a/email/token_ledger_store.ex) ----------------------------
      wave3(
        "token_ledger_put_unconditional",
        "token consumption without insert-if-absent",
        AshA2A.Email.TokenLedgerStore,
        :do_reserve,
        4,
        :all,
        ~S"""
        ChicagoKeys = lists:usort([key(ChicagoArg2, ChicagoN, ChicagoT) || {ChicagoN, ChicagoT} <- ChicagoArg3]),
        lists:foreach(fun(ChicagoK) -> 'Elixir.EKV':put(ChicagoArg1, ChicagoK, #{mid => ChicagoArg4}) end, ChicagoKeys),
        ok.
        """,
        "TokenLedgerStore.do_reserve/4 EKV.put(..., if_vsn: nil) consumes a token exactly once (:already_consumed)"
      ),
      # --- status tables and classifiers ------------------------------------------------------
      wave3(
        "error_bindings_table_corrupt",
        "corrupt the single error-status table",
        AshA2A.Protocol.JSONRPC.Error,
        :bindings,
        1,
        {:clause, 1},
        ~S"""
        #{-32001 => {500, 13, <<"INTERNAL">>}}.
        """,
        "JSONRPC.Error.bindings(:all): the one mapping of every error code to its HTTP/gRPC status"
      ),
      wave3(
        "error_bindings_a2a_scope_all",
        "A2A scope returns every row",
        AshA2A.Protocol.JSONRPC.Error,
        :bindings,
        1,
        {:clause, 2},
        "'bindings'(all).",
        "JSONRPC.Error.bindings(:a2a): only -32001..-32010"
      ),
      wave3(
        "admission_refusal_never",
        "admission refusals classified as failures",
        AshA2A.Transport.Runtime,
        :admission_refusal?,
        1,
        :all,
        "false.",
        "Transport.Runtime.admission_refusal?/1: a refusal is REJECTED, not FAILED"
      ),
      wave3(
        "admission_refusal_always",
        "every failure classified as an admission refusal",
        AshA2A.Transport.Runtime,
        :admission_refusal?,
        1,
        {:clause, 10},
        "true.",
        "Transport.Runtime.admission_refusal?/1 fallback: any other reason is FAILED, not REJECTED"
      ),
      # --- JSON ---------------------------------------------------------------------------------
      wave3(
        "json_guard_depth_ok",
        "no depth cap on untrusted JSON",
        AshA2A.Protocol.JSONGuard,
        :within_depth?,
        2,
        :all,
        "true.",
        "JSONGuard.within_depth?/2 nesting cap ({:nesting_exceeded, max})"
      ),
      wave3(
        "json_decode_not_total",
        "decoder raises on a non-object payload",
        AshA2A.Protocol.JSON,
        :decode,
        2,
        {:clause, 1},
        "erlang:error(badarg).",
        "Protocol.JSON.decode/2 totality: a non-object is {:error, {:invalid_field, type}}"
      ),
      # --- event journal ------------------------------------------------------------------------
      wave3(
        "journal_record_task_noop",
        "task writes are not journaled",
        AshA2A.Protocol.EventJournal,
        :record_task,
        3,
        {:clause, 2},
        "ok.",
        "EventJournal.record_task/3 appends one event per mutation"
      ),
      wave3(
        "journal_append_unverified",
        "append reports :ok without storing or reading back",
        AshA2A.TaskStore.EventJournalEts,
        :append,
        4,
        :all,
        "ok.",
        "EventJournalEts.append/4 stores the event and reads it back (:not_stored)"
      ),
      # --- control-plane TLS (lib/ash_a2a/c2/l07_tls/transport.ex) --------------------------------
      wave3(
        "tls_verify_peer_off",
        "TLS without peer verification",
        AshA2A.C2.L07Tls.Transport,
        :tls_options,
        1,
        {:clause, 1},
        ~S"""
        {ok, maps:get(host, ChicagoArg1), maps:get(port, ChicagoArg1),
         [{verify, verify_none}, {server_name_indication, binary_to_list(maps:get(host, ChicagoArg1))},
          {cert, maps:get(cert, ChicagoArg1)}, {key, maps:get(key, ChicagoArg1)}]}.
        """,
        "L07Tls.Transport.tls_options/1 verify: :verify_peer against the pinned CA"
      ),
      wave3(
        "tls_downgrade_to_uds",
        "configured TLS falls back to the unix socket",
        AshA2A.C2.L07Tls.Transport,
        :connect,
        4,
        :all,
        "'connect_uds'(ChicagoArg1, ChicagoArg3, ChicagoArg4).",
        "L07Tls.Transport.connect/4 never downgrades when :c2_tls is configured"
      ),
      # --- agent card signature (lib/ash_a2a/protocol/agent_card_signature.ex) ----------------------
      wave3(
        "card_alg_allowlist_ok",
        "accept any alg (alg none, :allowed_algs ignored)",
        AshA2A.Protocol.AgentCardSignature,
        :check_alg,
        2,
        {:clause, 1},
        "ok.",
        "AgentCardSignature.check_alg/2 alg is in :allowed_algs ({:alg_not_allowed, alg})"
      ),
      wave3(
        "card_key_alg_ok",
        "accept an alg that does not fit the key",
        AshA2A.Protocol.AgentCardSignature,
        :check_key_alg,
        2,
        :all,
        "ok.",
        "AgentCardSignature.check_key_alg/2 alg matches the JWK kty/crv (:alg_key_mismatch)"
      ),
      wave3(
        "card_signature_verify_true",
        "card signature always verifies",
        AshA2A.Protocol.AgentCardSignature,
        :raw_verify,
        4,
        :all,
        "true.",
        "AgentCardSignature.raw_verify/4 cryptographic verification (:bad_signature)"
      ),
      # --- task owner gate -----------------------------------------------------------------------
      wave3(
        "task_owner_gate_open",
        "every principal owns every task",
        AshA2A.Transport.Runtime,
        :owned_by?,
        2,
        :all,
        "true.",
        "Transport.Runtime.owned_by?/2 owner and tenant gate of tasks/get, list, cancel and references"
      )
    ]
  end

  defp wave3(id, rfc, module, function, arity, clauses, body, guard) do
    %Mutation{
      id: id,
      rfc_mutation: rfc,
      module: module,
      function: function,
      arity: arity,
      clauses: clauses,
      operator: {:replace_body, body},
      guard: guard,
      killers: [@wave3_killer]
    }
  end

  @doc "`[{court_falsifier_id, mutation}]` -- append-only numbering."
  @spec numbered() :: [{String.t(), Mutation.t()}]
  def numbered do
    entries()
    |> Enum.with_index(1)
    |> Enum.map(fn {m, i} ->
      {"SA2A-MUTATION-" <> String.pad_leading(Integer.to_string(i), 3, "0"), m}
    end)
  end

  @spec ids() :: [String.t()]
  def ids, do: Enum.map(entries(), & &1.id)

  @spec fetch(String.t()) :: {:ok, Mutation.t()} | :error
  def fetch(id) do
    case Enum.find(entries(), &(&1.id == id)) do
      nil -> :error
      m -> {:ok, m}
    end
  end

  @spec fetch!(String.t()) :: Mutation.t()
  def fetch!(id) do
    case fetch(id) do
      {:ok, m} -> m
      :error -> raise ArgumentError, "unknown mutation #{inspect(id)}; known: #{inspect(ids())}"
    end
  end

  @doc """
  Static resolution of every entry without loading anything: whether the
  target builds a mutant and which killer courts exist in this subject.
  """
  @spec resolution(keyword()) :: [map()]
  def resolution(opts \\ []) do
    for m <- entries() do
      target =
        case Mutation.prepare(m) do
          {:ok, plan} -> %{status: :resolvable, clauses_mutated: plan.clauses_mutated}
          {:error, refusal} -> %{status: :blocked, code: refusal.code, detail: refusal.detail}
        end

      killers =
        case Mutation.killer_courts(m, opts) do
          {:ok, courts, missing} -> %{resolved: Enum.map(courts, & &1.id()), missing: missing}
          {:error, refusal} -> %{resolved: [], missing: m.killers, code: refusal.code}
        end

      %{
        id: m.id,
        target: Mutation.target(m),
        rfc_mutation: m.rfc_mutation,
        target_status: target,
        killers: killers
      }
    end
  end
end
