# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule C2Harness.Catalog do
  @moduledoc """
  The RFC-SA2A-006 s26 attack catalog against the real Actuator (fence attacks, wire,
  injection payloads) and the real AuthorityService. Crash/fault attacks live in
  `C2Harness.Faults`.

  ID scheme: `C2C-A<nn>` actuator, `C2C-F<nn>` fault injection, `C2C-B<nn>` authority.
  Every attack states (a) which s26 items it covers, (b) the fence checks it reaches, and (c)
  the refusal it must observe, so a refusal for an unrelated reason cannot pass as evidence.

  Notation: `issue!` = an INTENDED issuance recorded in the issuance journal; `misissue!` =
  a validly signed certificate that is NOT journaled (an authority defect or a mis-signed
  artifact: the actuator is the independent second line, and any ledger entry it causes is
  unauthorized by definition).
  """
  alias C2Harness.{Attack, Attacker, Env, Wire}

  defp m(attck, capec, atlas \\ ["AML.T0053"]), do: %{attck: attck, capec: capec, atlas: atlas}

  defp a(id, title, s26, opts, run) do
    struct!(Attack, Keyword.merge([id: id, title: title, s26: s26, run: run], opts))
  end

  defp kid(cp, name), do: Enum.find(cp.public_registry.signers, &(&1["name"] == name))["kid"]
  defp put_entry(map, v), do: put_in(map, ["params", "entry"], v)
  defp res(authorized, notes \\ []), do: %{authorized: authorized, notes: notes}

  def actuator_attacks do
    [
      # ---- forged / substituted artifacts ----------------------------------------------------
      a(
        "C2C-A01",
        "forged PreparedEffect under a valid certificate",
        ["forged PreparedEffect"],
        [
          checks: [2],
          killers_for: [2],
          expect: ["effect_digest_mismatch"],
          mapping: m(["T1565", "T1550"], ["CAPEC-194", "CAPEC-153"])
        ],
        fn env ->
          e = Env.effect()
          l = Env.issue!(env, e)
          forged = Attacker.mutate_effect(l.effect, &put_entry(&1, "FORGED"))
          Env.submit(env, forged, l.cert)
          other = Env.bytes(Env.effect())
          Env.submit(env, other, l.cert)
          res([])
        end
      ),
      a(
        "C2C-A02",
        "certificate signed by keys absent from the actuator's pinned registry",
        ["forged certificate"],
        [
          checks: [10],
          expect: ["unknown_kid"],
          mapping: m(["T1606", "T1550"], ["CAPEC-196", "CAPEC-151"])
        ],
        fn env ->
          eb = Env.bytes(Env.effect())
          sigs = for _ <- 1..2, do: %{key: Attacker.own_key(), nonce: Attacker.nonce()}
          Env.submit(env, eb, Attacker.forge_cert(env.cp, eb, sigs))
          res([])
        end
      ),
      a(
        "C2C-A03",
        "kid spoofing: compromised signer signs while claiming another signer's kid",
        ["forged certificate"],
        [
          checks: [10],
          expect_any: ["bad_signature", "kid_key_mismatch"],
          mapping: m(["T1606"], ["CAPEC-196", "CAPEC-151"])
        ],
        fn env ->
          eb = Env.bytes(Env.effect())
          k = Attacker.compromised(env.cp, "A")

          sigs = [
            %{key: k, nonce: Attacker.nonce()},
            %{key: k, nonce: Attacker.nonce(), label_kid: kid(env.cp, "B")}
          ]

          Env.submit(env, eb, Attacker.forge_cert(env.cp, eb, sigs))
          res([])
        end
      ),
      a(
        "C2C-A04",
        "fake standing / smuggled public keys inside the certificate",
        ["fake standing"],
        [checks: [], expect: ["malformed_certificate"], mapping: m(["T1606"], ["CAPEC-194"])],
        fn env ->
          l = Env.issue!(env, Env.effect())

          smuggle = fn c ->
            Map.merge(c, %{"standing" => "valid", "public_keys" => %{"x" => "y"}})
          end

          Env.submit(env, l.effect, Attacker.mutate_cert(l.cert, smuggle))

          in_sig = fn c ->
            Map.update!(c, "signatures", fn [s | rest] ->
              [Map.put(s, "public_key", Attacker.b64("k")) | rest]
            end)
          end

          Env.submit(env, l.effect, Attacker.mutate_cert(l.cert, in_sig))
          res([])
        end
      ),
      a(
        "C2C-A05",
        "forged receipt and administrative operations over the wire",
        ["forged internal receipt", "policy-option removal"],
        [
          checks: [],
          expect: ["malformed_request"],
          mapping: m(["T1562", "T1190"], ["CAPEC-1", "CAPEC-220"])
        ],
        fn env ->
          for op <- ~w(receipt reconcile set_policy set_revocation revoke exec shell health_off) do
            Env.frame(
              env,
              Jason.encode!(%{
                "op" => op,
                "effect_instance_id" => "ei:0001-abcdef",
                "resolution" => "confirmed_not_performed"
              })
            )
          end

          Env.frame(env, Jason.encode!(%{"op" => "status"}))
          res([])
        end
      ),
      # ---- mutated subject / input -----------------------------------------------------------------
      a(
        "C2C-A06",
        "mutated exact subject after signing",
        ["mutated exact subject"],
        [
          checks: [2],
          killers_for: [2],
          expect: ["effect_digest_mismatch"],
          mapping: m(["T1565"], ["CAPEC-153", "CAPEC-194"])
        ],
        fn env ->
          l = Env.issue!(env, Env.effect())

          Env.submit(
            env,
            Attacker.mutate_effect(l.effect, &Map.put(&1, "subject", "subject:orders/43")),
            l.cert
          )

          res([])
        end
      ),
      a(
        "C2C-A07",
        "signed effect whose subject is outside the actuator's allowed set",
        ["mutated exact subject"],
        [
          checks: [4],
          killers_for: [4],
          expect: ["subject_not_allowed"],
          mapping: m(["T1078"], ["CAPEC-1", "CAPEC-153"])
        ],
        fn env ->
          for s <- ["subject:payroll/1", "subject:orders/42/../../etc", "SUBJECT:ORDERS/42"] do
            l = Env.misissue!(env, Env.effect(%{"subject" => s}))
            Env.submit(env, l.effect, l.cert)
          end

          res([])
        end
      ),
      a(
        "C2C-A08",
        "mutated canonical input and non-canonical encodings",
        ["mutated canonical input"],
        [
          checks: [2],
          killers_for: [2],
          expect: ["effect_digest_mismatch", "non_canonical_effect"],
          mapping: m(["T1565"], ["CAPEC-153"])
        ],
        fn env ->
          e = Env.effect()
          l = Env.issue!(env, e)
          Env.submit(env, Attacker.mutate_effect(l.effect, &put_entry(&1, "mutated")), l.cert)

          Env.submit(
            env,
            Attacker.mutate_effect(l.effect, &Map.put(&1, "principal", "agent:mallory")),
            l.cert
          )

          Env.submit(env, Attacker.noncanonical(e), l.cert)
          res([])
        end
      ),
      # ---- request identity, replay, duplication -----------------------------------------------------
      a(
        "C2C-A09",
        "fresh request id for an existing effect instance",
        ["fresh request id for an existing effect instance"],
        [
          checks: [2, 15],
          expect: ["performed", "effect_digest_mismatch"],
          mapping: m(["T1550"], ["CAPEC-60", "CAPEC-21"])
        ],
        fn env ->
          l = Env.issue!(env, Env.effect())
          Env.submit(env, l.effect, l.cert)

          fresh =
            Attacker.mutate_effect(
              l.effect,
              &Map.put(&1, "effect_instance_id", "ei:fresh-" <> Attacker.nonce())
            )

          Env.submit(env, fresh, l.cert)
          again = Env.issue(env, l.effect)
          if again == {:error, "already_issued"}, do: Env.note(env, "authority_refused_reissue")
          res([l.digest], [{:reissue, again}])
        end
      ),
      a(
        "C2C-A10",
        "replay of a valid certificate after completion (also across actuator restart)",
        ["replay of a valid certificate", "duplicated DO"],
        [
          checks: [15],
          killers_for: [15],
          expect: ["performed", "replayed"],
          mapping: m(["T1550"], ["CAPEC-60"])
        ],
        fn env ->
          l = Env.issue!(env, Env.effect())
          Env.submit(env, l.effect, l.cert)
          for _ <- 1..5, do: Env.submit(env, l.effect, l.cert)
          Env.restart_actuator(env)
          Env.wait_healthy(env)
          for _ <- 1..3, do: Env.submit(env, l.effect, l.cert)
          res([l.digest])
        end
      ),
      a(
        "C2C-A22",
        "concurrent claim of one effect from twelve connections",
        ["duplicated DO"],
        [
          checks: [14, 15],
          killers_for: [15],
          expect: ["performed"],
          mapping: m(["T1499", "T1550"], ["CAPEC-26", "CAPEC-29"])
        ],
        fn env ->
          l = Env.issue!(env, Env.effect())

          results =
            1..12
            |> Task.async_stream(fn _ -> Env.submit(env, l.effect, l.cert) end,
              max_concurrency: 12,
              timeout: 60_000
            )
            |> Enum.map(fn {:ok, r} -> r[:status] || r[:refusal] end)

          res([l.digest], [{:statuses, Enum.frequencies(results)}])
        end
      ),
      a(
        "C2C-A44",
        "one (kid, nonce) pair reused to authorize a second effect instance",
        ["duplicated DO", "replay of a valid certificate"],
        [
          checks: [14],
          killers_for: [14],
          expect: ["performed", "nonce_replayed"],
          mapping: m(["T1550"], ["CAPEC-60"])
        ],
        fn env ->
          [n1, n2] = [Attacker.nonce(), Attacker.nonce()]
          l1 = Env.issue!(env, Env.effect(), nonces: [n1, n2])
          l2 = Env.misissue!(env, Env.effect(), nonces: [n1, n2])
          Env.submit(env, l1.effect, l1.cert)
          Env.submit(env, l2.effect, l2.cert)
          res([l1.digest])
        end
      ),
      # ---- certificate validity ------------------------------------------------------------------------
      a(
        "C2C-A11",
        "expired certificate",
        ["expired certificate"],
        [
          checks: [12],
          killers_for: [12],
          expect: ["expired"],
          mapping: m(["T1550"], ["CAPEC-60"])
        ],
        fn env ->
          l = Env.issue!(env, Env.effect(), not_before_off: -1000, expires_off: -700)
          Env.submit(env, l.effect, l.cert)
          res([])
        end
      ),
      a(
        "C2C-A12",
        "not-yet-valid certificate beyond the skew allowance",
        ["expired certificate"],
        [
          checks: [12],
          killers_for: [12],
          expect: ["not_yet_valid"],
          mapping: m(["T1550"], ["CAPEC-29"])
        ],
        fn env ->
          l = Env.issue!(env, Env.effect(), not_before_off: 600, expires_off: 900)
          Env.submit(env, l.effect, l.cert)
          res([])
        end
      ),
      a(
        "C2C-A13",
        "certificate with a lifetime above the actuator TTL ceiling",
        ["expired certificate"],
        [
          checks: [12],
          killers_for: [12],
          expect: ["ttl_too_long"],
          mapping: m(["T1550"], ["CAPEC-29"])
        ],
        fn env ->
          l = Env.misissue!(env, Env.effect(), expires_off: 3600)
          Env.submit(env, l.effect, l.cert)
          res([])
        end
      ),
      a(
        "C2C-A14",
        "certificate whose window is malformed (expires <= not_before)",
        ["expired certificate"],
        [
          checks: [10, 12],
          expect_any: ["malformed_window", "malformed_envelope"],
          mapping: m(["T1550"], ["CAPEC-153"])
        ],
        fn env ->
          l = Env.misissue!(env, Env.effect(), not_before_off: 100, expires_off: 50)
          Env.submit(env, l.effect, l.cert)
          res([])
        end
      ),
      a(
        "C2C-A15",
        "stale policy epoch on the certificate and on the effect",
        ["stale policy epoch"],
        [
          checks: [9],
          killers_for: [9],
          expect: ["policy_epoch_stale"],
          mapping: m(["T1562"], ["CAPEC-176"])
        ],
        fn env ->
          l = Env.misissue!(env, Env.effect(), policy_epoch: 2)
          Env.submit(env, l.effect, l.cert)
          l2 = Env.misissue!(env, Env.effect(%{"policy_epoch" => 2}))
          Env.submit(env, l2.effect, l2.cert)
          res([])
        end
      ),
      a(
        "C2C-A16",
        "certificate older than the actuator's revocation epoch",
        ["revoked authority"],
        [
          checks: [13],
          killers_for: [13],
          expect: ["revocation_epoch_stale"],
          mapping: m(["T1550"], ["CAPEC-60"])
        ],
        fn env ->
          Env.revoke(env, %{"epoch" => 8})
          l = Env.issue!(env, Env.effect())
          Env.submit(env, l.effect, l.cert)
          res([])
        end
      ),
      a(
        "C2C-A17",
        "certificate signed by a key the actuator's revocation view lists as revoked",
        ["revoked authority"],
        [
          checks: [13],
          killers_for: [13],
          expect: ["key_revoked"],
          mapping: m(["T1078", "T1550"], ["CAPEC-60"])
        ],
        fn env ->
          Env.revoke(env, %{"revoked" => [kid(env.cp, "A")]})
          l = Env.issue!(env, Env.effect())
          Env.submit(env, l.effect, l.cert)
          res([])
        end
      ),
      a(
        "C2C-A18",
        "stale and missing revocation view (fail closed)",
        ["revoked authority"],
        [
          checks: [13],
          killers_for: [13],
          expect: ["revocation_view_stale", "revocation_view_missing"],
          mapping: m(["T1562"], ["CAPEC-176"])
        ],
        fn env ->
          l = Env.issue!(env, Env.effect())
          Env.revoke(env, %{"refreshed_at" => Env.now() - 4000})
          Env.submit(env, l.effect, l.cert)
          Env.revoke(env, :delete)
          Env.submit(env, l.effect, l.cert)
          res([])
        end
      ),
      # ---- quorum ------------------------------------------------------------------------------------------
      a(
        "C2C-A19",
        "insufficient quorum (1 valid signature where 2 custodians are required)",
        ["insufficient quorum"],
        [
          checks: [11],
          killers_for: [11],
          expect: ["quorum_not_met"],
          mapping: m(["T1078"], ["CAPEC-1"])
        ],
        fn env ->
          l = Env.misissue!(env, Env.effect(), signers: ["B"])
          Env.submit(env, l.effect, l.cert)
          res([])
        end
      ),
      a(
        "C2C-A20",
        "single compromised signer below k, alone and with repeated nonces",
        ["single compromised signer below quorum"],
        [
          checks: [11],
          killers_for: [11],
          expect: ["quorum_not_met"],
          mapping: m(["T1078", "T1606"], ["CAPEC-196", "CAPEC-151"])
        ],
        fn env ->
          k = Attacker.compromised(env.cp, "A")
          eb = Env.bytes(Env.effect())

          Env.submit(
            env,
            eb,
            Attacker.forge_cert(env.cp, eb, [%{key: k, nonce: Attacker.nonce()}])
          )

          eb2 = Env.bytes(Env.effect())

          Env.submit(
            env,
            eb2,
            Attacker.forge_cert(env.cp, eb2, [
              %{key: k, nonce: Attacker.nonce()},
              %{key: k, nonce: Attacker.nonce()}
            ])
          )

          res([])
        end
      ),
      a(
        "C2C-A21",
        "one custodian signing twice with two keys (independence tier I3)",
        ["single compromised signer below quorum"],
        [
          checks: [11],
          killers_for: [11],
          expect: ["quorum_not_met"],
          mapping: m(["T1078"], ["CAPEC-151"])
        ],
        fn env ->
          eb = Env.bytes(Env.effect())

          sigs =
            for n <- ["A", "A2"],
                do: %{key: Attacker.compromised(env.cp, n), nonce: Attacker.nonce()}

          Env.submit(env, eb, Attacker.forge_cert(env.cp, eb, sigs))
          res([])
        end
      ),
      # ---- protocol / schema / class / capability -----------------------------------------------------------
      a(
        "C2C-A37",
        "certificate for a generation the actuator does not hold",
        ["replay of a valid certificate"],
        [
          checks: [16],
          killers_for: [16],
          expect: ["generation_stale"],
          mapping: m(["T1550"], ["CAPEC-60"])
        ],
        fn env ->
          l = Env.misissue!(env, Env.effect(), generation: 2)
          Env.submit(env, l.effect, l.cert)
          res([])
        end
      ),
      a(
        "C2C-A38",
        "certificate minted for another audience",
        ["forged certificate"],
        [checks: [10], expect: ["wrong_audience"], mapping: m(["T1550"], ["CAPEC-21"])],
        fn env ->
          l = Env.misissue!(env, Env.effect(), audience: "actuator:other")
          Env.submit(env, l.effect, l.cert)
          res([])
        end
      ),
      a(
        "C2C-A39",
        "certificate principal differs from the effect principal",
        ["forged capability"],
        [
          checks: [3],
          killers_for: [3],
          expect: ["principal_mismatch"],
          mapping: m(["T1078"], ["CAPEC-151"])
        ],
        fn env ->
          l = Env.misissue!(env, Env.effect(), principal: "agent:mallory")
          Env.submit(env, l.effect, l.cert)
          res([])
        end
      ),
      a(
        "C2C-A40",
        "capability that is not the effector's own capability",
        ["forged capability"],
        [
          checks: [5],
          killers_for: [5],
          expect: ["capability_mismatch"],
          mapping: m(["T1078"], ["CAPEC-1"])
        ],
        fn env ->
          l = Env.misissue!(env, Env.effect(%{"capability" => "actuator.noop.probe"}))
          Env.submit(env, l.effect, l.cert)
          l2 = Env.misissue!(env, Env.effect(%{"capability" => "actuator.admin.everything"}))
          Env.submit(env, l2.effect, l2.cert)
          res([])
        end
      ),
      a(
        "C2C-A41",
        "consequence class below the effector's registered class",
        ["forged capability"],
        [
          checks: [6],
          killers_for: [6],
          expect: ["consequence_class_mismatch"],
          mapping: m(["T1078"], ["CAPEC-1"])
        ],
        fn env ->
          l = Env.misissue!(env, Env.effect(%{"consequence_class" => "none"}))
          Env.submit(env, l.effect, l.cert)
          res([])
        end
      ),
      a(
        "C2C-A42",
        "unsupported protocol version on effect and certificate",
        ["forged PreparedEffect"],
        [
          checks: [1],
          killers_for: [1],
          expect: ["unsupported_protocol_version"],
          mapping: m(["T1565"], ["CAPEC-220"])
        ],
        fn env ->
          l = Env.misissue!(env, Env.effect(%{"v" => 2}), v: 2)
          Env.submit(env, l.effect, l.cert)
          res([])
        end
      ),
      a(
        "C2C-A43",
        "malformed effect-instance identity",
        ["fresh request id for an existing effect instance"],
        [
          checks: [7],
          killers_for: [7],
          expect: ["bad_effect_instance"],
          mapping: m(["T1059"], ["CAPEC-88", "CAPEC-153"])
        ],
        fn env ->
          for id <- ["has space in it", "ei", "ei:1;touch /tmp/c2-pwned"] do
            l = Env.misissue!(env, Env.effect(%{"effect_instance_id" => id}))
            Env.submit(env, l.effect, l.cert)
          end

          res([])
        end
      ),
      # ---- policy option removal / structure ----------------------------------------------------------------
      a(
        "C2C-A28",
        "policy-option removal: required effect and certificate fields deleted",
        ["policy-option removal"],
        [
          checks: [],
          expect: ["malformed_effect", "malformed_certificate"],
          mapping: m(["T1562"], ["CAPEC-153"])
        ],
        fn env ->
          e = Env.effect()

          for k <- ["resource_bounds", "capability", "consequence_class", "policy_epoch"] do
            l = Env.misissue!(env, Env.bytes(Map.delete(e, k)))
            Env.submit(env, l.effect, l.cert)
          end

          l = Env.issue!(env, Env.effect())

          for k <- ["generation", "audience", "expires", "effect_digest"] do
            Env.submit(env, l.effect, Attacker.mutate_cert(l.cert, &Map.delete(&1, k)))
          end

          Env.submit(env, l.effect, Attacker.mutate_cert(l.cert, &Map.put(&1, "signatures", [])))
          res([])
        end
      ),
      a(
        "C2C-A34",
        "swapped or downgraded signature algorithm",
        ["forged certificate"],
        [
          checks: [10],
          expect_any:
            ~w(unsupported_algorithm malformed_envelope alg_mismatch unsupported_suite profile_mismatch),
          mapping: m(["T1606"], ["CAPEC-196"])
        ],
        fn env ->
          k = Attacker.compromised(env.cp, "A")

          for alg <- ["none", "EdDSA", "HS256", "ES256K", "ML-DSA-65"] do
            eb = Env.bytes(Env.effect())

            sigs = [
              %{key: k, nonce: Attacker.nonce(), label_alg: alg},
              %{key: k, nonce: Attacker.nonce(), label_alg: alg}
            ]

            Env.submit(env, eb, Attacker.forge_cert(env.cp, eb, sigs))
          end

          res([])
        end
      ),
      a(
        "C2C-A35",
        "truncated and oversized certificate and effect",
        ["arbitrary deserialization payload"],
        [
          checks: [],
          expect: ["malformed_certificate", "malformed_effect"],
          mapping: m(["T1499", "T1190"], ["CAPEC-130", "CAPEC-153"], ["AML.T0029"])
        ],
        fn env ->
          l = Env.issue!(env, Env.effect())
          Env.submit(env, l.effect, binary_part(l.cert, 0, div(byte_size(l.cert), 2)))
          Env.submit(env, binary_part(l.effect, 0, div(byte_size(l.effect), 2)), l.cert)

          padded =
            Attacker.mutate_cert(
              l.cert,
              &Map.put(&1, "signatures", [%{"pad" => String.duplicate("A", 70_000)}])
            )

          Env.submit(env, l.effect, padded)
          res([])
        end
      ),
      a(
        "C2C-A36",
        "clock skew: within the allowance accepted, beyond it and after expiry refused",
        ["expired certificate"],
        [
          checks: [12],
          killers_for: [12],
          expect: ["performed", "not_yet_valid", "expired"],
          mapping: m(["T1550"], ["CAPEC-29"])
        ],
        fn env ->
          ok = Env.issue!(env, Env.effect(), not_before_off: 20, expires_off: 320)
          Env.submit(env, ok.effect, ok.cert)
          far = Env.issue!(env, Env.effect(), not_before_off: 150, expires_off: 450)
          Env.submit(env, far.effect, far.cert)
          short = Env.issue!(env, Env.effect(), not_before_off: -60, expires_off: 3)
          Process.sleep(4_500)
          Env.submit(env, short.effect, short.cert)
          res([ok.digest])
        end
      ),
      # ---- resource / injection payloads -----------------------------------------------------------------------
      a(
        "C2C-A33",
        "resource-budget amplification: declared bounds, oversized entries, frames and signature lists",
        ["resource-budget amplification"],
        [
          checks: [8],
          killers_for: [8],
          expect: [
            "resource_bounds_exceeded",
            "malformed_certificate",
            "malformed_effect",
            "transport_closed"
          ],
          mapping: m(["T1499"], ["CAPEC-130", "CAPEC-125"], ["AML.T0029"])
        ],
        fn env ->
          l1 = Env.misissue!(env, Env.effect(%{"resource_bounds" => %{"max_bytes" => 1_000_000}}))
          Env.submit(env, l1.effect, l1.cert)
          big = Env.effect(%{"params" => %{"entry" => String.duplicate("x", 300)}})
          l2 = Env.misissue!(env, big)
          Env.submit(env, l2.effect, l2.cert)
          eb = Env.bytes(Env.effect())
          nine = for _ <- 1..9, do: %{key: Attacker.own_key(), nonce: Attacker.nonce()}
          Env.submit(env, eb, Attacker.forge_cert(env.cp, eb, nine))
          Env.submit(env, String.duplicate("e", 20_000), l1.cert)
          Env.frame(env, String.duplicate("z", 200_000))
          res([])
        end
      ),
      a(
        "C2C-A29",
        "path substitution in params, subject and effect type",
        ["path substitution"],
        [
          checks: [4],
          expect: ["malformed_effect", "unknown_effect_type", "subject_not_allowed", "performed"],
          mapping: m(["T1083", "T1565"], ["CAPEC-126"])
        ],
        fn env ->
          marker = "/tmp/c2-pwned-path-" <> Attacker.nonce()

          l1 =
            Env.misissue!(
              env,
              Env.effect(%{"params" => %{"entry" => "x", "path" => "/etc/passwd"}})
            )

          Env.submit(env, l1.effect, l1.cert)
          l2 = Env.misissue!(env, Env.effect(%{"subject" => "/etc/passwd"}))
          Env.submit(env, l2.effect, l2.cert)

          l3 =
            Env.misissue!(
              env,
              Env.effect(%{
                "effect_type" => "file_write",
                "params" => %{"path" => marker, "data" => "x"}
              })
            )

          Env.submit(env, l3.effect, l3.cert)

          l4 =
            Env.issue!(
              env,
              Env.effect(%{"params" => %{"entry" => "../../../../../.." <> marker}})
            )

          Env.submit(env, l4.effect, l4.cert)
          inert = not File.exists?(marker)
          if inert, do: Env.note(env, "path_payload_inert")
          res([l4.digest], [{:path_payload_inert, inert}])
        end
      ),
      a(
        "C2C-A30",
        "URL substitution in params and effect type",
        ["arbitrary URL substitution"],
        [
          checks: [],
          expect: ["malformed_effect", "unknown_effect_type", "performed"],
          mapping: m(["T1090", "T1071"], ["CAPEC-664"])
        ],
        fn env ->
          l1 =
            Env.misissue!(
              env,
              Env.effect(%{"params" => %{"entry" => "x", "url" => "http://127.0.0.1:1/exfil"}})
            )

          Env.submit(env, l1.effect, l1.cert)

          l2 =
            Env.misissue!(
              env,
              Env.effect(%{
                "effect_type" => "http_request",
                "params" => %{"url" => "http://169.254.169.254/"}
              })
            )

          Env.submit(env, l2.effect, l2.cert)

          l3 =
            Env.issue!(
              env,
              Env.effect(%{"params" => %{"entry" => "http://169.254.169.254/latest/meta-data"}})
            )

          Env.submit(env, l3.effect, l3.cert)
          res([l3.digest])
        end
      ),
      a(
        "C2C-A31",
        "command injection in effect type, params, subject and entry",
        ["command injection"],
        [
          checks: [4],
          expect: ["malformed_effect", "unknown_effect_type", "subject_not_allowed", "performed"],
          mapping: m(["T1059"], ["CAPEC-88"])
        ],
        fn env ->
          marker = "/tmp/c2-pwned-cmd-" <> Attacker.nonce()
          cmd = "$(touch #{marker}); `touch #{marker}`; touch #{marker}"

          l1 =
            Env.misissue!(
              env,
              Env.effect(%{"effect_type" => "shell", "params" => %{"cmd" => cmd}})
            )

          Env.submit(env, l1.effect, l1.cert)
          l2 = Env.misissue!(env, Env.effect(%{"params" => %{"entry" => "x", "cmd" => cmd}}))
          Env.submit(env, l2.effect, l2.cert)

          l3 =
            Env.misissue!(env, Env.effect(%{"subject" => "subject:orders/42; touch #{marker}"}))

          Env.submit(env, l3.effect, l3.cert)
          l4 = Env.issue!(env, Env.effect(%{"params" => %{"entry" => cmd}}))
          Env.submit(env, l4.effect, l4.cert)
          inert = not File.exists?(marker)
          if inert, do: Env.note(env, "command_payload_inert")
          res([l4.digest], [{:command_payload_inert, inert}])
        end
      ),
      a(
        "C2C-A32",
        "arbitrary deserialization payloads (external term format, struct keys, deep nesting)",
        ["arbitrary deserialization payload"],
        [
          checks: [],
          expect: ["malformed_request", "malformed_effect"],
          mapping: m(["T1190", "T1203"], ["CAPEC-586"])
        ],
        fn env ->
          Env.frame(env, :erlang.term_to_binary(%{"op" => "execute"}))
          Env.frame(env, :erlang.term_to_binary({:op, :execute, [<<0, 1, 2>>]}, [:compressed]))
          etf = :erlang.term_to_binary(%{"__struct__" => System})
          Env.frame(env, Wire.execute_frame(etf, etf))

          l1 =
            Env.misissue!(
              env,
              Env.effect(%{"params" => %{"entry" => "x", "__struct__" => "Elixir.System"}})
            )

          Env.submit(env, l1.effect, l1.cert)
          deep = String.duplicate("[", 6000) <> String.duplicate("]", 6000)
          Env.frame(env, ~s({"op":"execute","effect":#{deep},"certificate":"x"}))
          res([])
        end
      ),
      # ---- alternate wire path (mTLS) -----------------------------------------------------------------------------
      a(
        "C2C-A27",
        "alternate wire path: mTLS port without / with rogue / with legitimate client credential",
        ["alternate adapter path"],
        [
          checks: [],
          expect: [
            "tls_plaintext_refused",
            "tls_no_client_cert_refused",
            "tls_rogue_client_refused",
            "tls_legit_client_served"
          ],
          mapping: m(["T1021", "T1557"], ["CAPEC-115", "CAPEC-220"])
        ],
        fn env -> alt_wire(env) end
      )
    ]
  end

  defp alt_wire(env) do
    cp = env.cp
    l = Env.issue!(env, Env.effect())
    frame = Wire.execute_frame(l.effect, l.cert)

    refused? = fn
      {:error, _} -> true
      {:ok, %{"ok" => true}} -> false
      {:ok, _} -> true
    end

    plain = Wire.plaintext_tcp(cp.tls_port, <<byte_size(frame)::32, frame::binary>>)

    if refused?.(plain) or not match?({:ok, <<0, _::binary>>}, plain),
      do: Env.note(env, "tls_plaintext_refused")

    if refused?.(Wire.tls(cp.tls_port, frame, [])),
      do: Env.note(env, "tls_no_client_cert_refused")

    rogue = [
      certfile: String.to_charlist(cp.rogue_client_cert),
      keyfile: String.to_charlist(cp.rogue_client_key)
    ]

    if refused?.(Wire.tls(cp.tls_port, frame, rogue)),
      do: Env.note(env, "tls_rogue_client_refused")

    good = [
      certfile: String.to_charlist(cp.tls_client_cert),
      keyfile: String.to_charlist(cp.tls_client_key)
    ]

    case Wire.tls(cp.tls_port, frame, good) do
      {:ok, %{"ok" => true, "status" => "performed"}} -> Env.note(env, "tls_legit_client_served")
      other -> Env.note(env, "tls_legit_client_unexpected:" <> inspect(other))
    end

    %{authorized: [l.digest], notes: [], iterations: 1}
  end
end
