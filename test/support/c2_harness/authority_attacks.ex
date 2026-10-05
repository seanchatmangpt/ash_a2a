# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule C2Harness.AuthorityAttacks do
  @moduledoc """
  Attacks against the REAL AuthorityService (separate OS process, release-style entrypoint,
  unix-socket wire). Oracle: its own hash-chained issuance journal, read by the harness.
  Rule: the journal gains only issuances the court authorized, and no
  `(effect_digest, generation)` pair is ever issued twice; the actuator ledger must not
  change at all during these attacks.

  Effects use the authority's own schema (`effect_class`, `amount`, ...): class `payment`,
  amount 500_000 (tier k = 2 of the approvers alice/bob/carol). The attacker holds one
  compromised approver (alice). Note the policy-defined residual: for a tier with k = 1 a
  single compromised approver IS sufficient by policy, so the claim "fewer than k" is
  per-class, not absolute.
  """
  alias C2Harness.{Attack, Attacker, Env, Wire}

  @gen 9

  defp m(attck, capec, atlas \\ ["AML.T0053"]), do: %{attck: attck, capec: capec, atlas: atlas}

  def attacks do
    [
      %Attack{
        id: "C2C-B01",
        title: "forged approvals signed by keys outside the approver registry",
        s26: ["forged capability", "fake standing"],
        scope: :authority,
        expect: ["insufficient_approvals"],
        mapping: m(["T1606", "T1550"], ["CAPEC-196", "CAPEC-151"]),
        run: fn env ->
          {e, d} = effect(env)
          apps = for _ <- 1..2, do: Attacker.approval(env.cp, Attacker.own_key(), d)
          issue(env, e, d, apps)
          %{authority_authorized: []}
        end
      },
      %Attack{
        id: "C2C-B02",
        title: "single compromised approver below k, alone and repeated with fresh nonces",
        s26: ["single compromised signer below quorum", "insufficient quorum"],
        scope: :authority,
        expect: ["insufficient_approvals"],
        mapping: m(["T1078", "T1606"], ["CAPEC-151", "CAPEC-196"]),
        run: fn env ->
          {e, d} = effect(env)
          alice = Attacker.compromised(env.cp, "alice")
          one = [Attacker.approval(env.cp, alice, d)]
          three = for _ <- 1..3, do: Attacker.approval(env.cp, alice, d)
          issue(env, e, d, one)
          issue(env, e, d, three)
          %{authority_authorized: []}
        end
      },
      %Attack{
        id: "C2C-B03",
        title: "effect mutated after human approval (approvals bind the original digest)",
        s26: ["mutated canonical input", "forged PreparedEffect"],
        scope: :authority,
        expect: ["insufficient_approvals", "issued"],
        mapping: m(["T1565"], ["CAPEC-153", "CAPEC-194"]),
        run: fn env ->
          {e, d} = effect(env)
          apps = approvals(env, d)
          e2 = Map.put(e, "amount", 900_000)
          issue(env, e2, Attacker.digest(Jcs.encode(e2)), apps)
          e3 = Map.put(e, "principal", "agent:mallory")
          issue(env, e3, Attacker.digest(Jcs.encode(e3)), apps)
          issue(env, e, d, apps)
          %{authority_authorized: [{d, @gen}]}
        end
      },
      %Attack{
        id: "C2C-B04",
        title:
          "approval replay: same approvals re-presented for the same effect, another generation, another effect",
        s26: ["replay of a valid certificate", "duplicated DO"],
        scope: :authority,
        expect: ["issued", "already_issued", "insufficient_approvals"],
        mapping: m(["T1550"], ["CAPEC-60"]),
        run: fn env ->
          {e, d} = effect(env)
          apps = approvals(env, d)
          issue(env, e, d, apps)
          issue(env, e, d, apps)
          issue(env, e, d, apps, generation: @gen + 1)
          {e2, d2} = effect(env)
          issue(env, e2, d2, apps)
          %{authority_authorized: [{d, @gen}]}
        end
      },
      %Attack{
        id: "C2C-B05",
        title: "stale-policy-epoch and expired approvals",
        s26: ["stale policy epoch", "expired certificate"],
        scope: :authority,
        expect: ["insufficient_approvals"],
        mapping: m(["T1550"], ["CAPEC-60", "CAPEC-29"]),
        run: fn env ->
          {e, d} = effect(env)

          stale = [
            Env.approve(env, "bob", d, policy_epoch: 2),
            Env.approve(env, "carol", d, policy_epoch: 2)
          ]

          old = [
            Env.approve(env, "bob", d, not_before_off: -400, expires_off: -100),
            Env.approve(env, "carol", d, not_before_off: -400, expires_off: -100)
          ]

          long = [
            Env.approve(env, "bob", d, expires_off: 100_000),
            Env.approve(env, "carol", d, expires_off: 100_000)
          ]

          for apps <- [stale, old, long], do: issue(env, e, d, apps)
          %{authority_authorized: []}
        end
      },
      %Attack{
        id: "C2C-B06",
        title: "duplicated issuance: eight concurrent connections presenting one valid request",
        s26: ["duplicated DO"],
        scope: :authority,
        expect: ["issued", "already_issued"],
        mapping: m(["T1499", "T1550"], ["CAPEC-26"]),
        run: fn env ->
          {e, d} = effect(env)
          apps = approvals(env, d)

          1..8
          |> Task.async_stream(fn _ -> issue(env, e, d, apps) end,
            max_concurrency: 8,
            timeout: 60_000
          )
          |> Stream.run()

          %{authority_authorized: [{d, @gen}]}
        end
      },
      %Attack{
        id: "C2C-B07",
        title: "malformed, oversized, wrong-op, external-term-format and lying-length frames",
        s26: ["arbitrary deserialization payload", "resource-budget amplification"],
        scope: :authority,
        expect: ["unknown_op", "malformed_request", "request_too_large"],
        mapping: m(["T1190", "T1499"], ["CAPEC-586", "CAPEC-130"], ["AML.T0029"]),
        run: fn env ->
          sock = env.cp.authority_sock
          obs(env, Wire.lp(sock, %{"op" => "exec", "cmd" => "touch /tmp/x"}))
          obs(env, Wire.lp(sock, {:raw, :erlang.term_to_binary(%{"op" => "issue"})}))
          obs(env, Wire.lp(sock, {:raw, "[1,2,3]"}))
          obs(env, Wire.lp(sock, {:raw, ""}))
          obs(env, Wire.lp_declared(sock, 50_000_000, "x"))
          {e, d} = effect(env)

          big = %{
            "op" => "issue",
            "effect" => Attacker.b64(String.duplicate("a", 40_000)),
            "effect_digest" => d,
            "audience" => "actuator:court",
            "generation" => @gen,
            "approvals" => []
          }

          obs(env, Wire.lp(sock, big))
          _ = e
          %{authority_authorized: []}
        end
      },
      %Attack{
        id: "C2C-B08",
        title: "authority SIGKILLed mid-issuance, restarted, request retried (N times)",
        s26: ["crash during uncertain DO", "duplicated DO"],
        scope: :authority,
        faults: true,
        expect_any: ["already_issued", "issued"],
        mapping: m(["T1499", "T1529"], ["CAPEC-26", "CAPEC-125"], ["AML.T0029"]),
        run: &authority_restart_series/1
      }
    ]
  end

  # ---- helpers ---------------------------------------------------------------------------------------------

  defp effect(_env) do
    e = %{
      "effect_class" => "payment",
      "amount" => 500_000,
      "principal" => "agent:alice",
      "target" => "acct:42",
      "idem" => Attacker.nonce()
    }

    {e, Attacker.digest(Jcs.encode(e))}
  end

  defp approvals(env, d), do: [Env.approve(env, "bob", d), Env.approve(env, "carol", d)]

  @doc false
  def issue(env, e, d, apps, opts \\ []) do
    req = %{
      "op" => "issue",
      "effect" => Attacker.b64(Jcs.encode(e)),
      "effect_digest" => d,
      "audience" => "actuator:court",
      "generation" => Keyword.get(opts, :generation, @gen),
      "approvals" => apps
    }

    obs(env, Wire.lp(env.cp.authority_sock, req))
  end

  defp obs(env, reply) do
    case reply do
      {:ok, %{"ok" => true}} -> Env.note(env, "issued")
      {:ok, %{"refusal" => r}} -> Env.note(env, r)
      _ -> Env.note(env, "transport_closed")
    end

    reply
  end

  defp authority_restart_series(env) do
    :rand.seed(:exsss, env.seed)

    rows =
      for _ <- 1..env.n do
        {e, d} = effect(env)
        apps = approvals(env, d)
        task = Task.async(fn -> issue(env, e, d, apps) end)
        Process.sleep(:rand.uniform(30) - 1)
        C2Harness.Fleet.kill_authority(env.fleet)
        first = Task.await(task, 60_000)
        :ok = C2Harness.Fleet.start_authority(env.fleet)
        retry = issue(env, e, d, apps)

        first_ok? = match?({:ok, %{"ok" => true}}, first)
        retry_ok? = match?({:ok, %{"ok" => true}}, retry)

        if first_ok? and retry_ok?,
          do: raise("two certificates issued for one (digest, generation)")

        %{digest: d, first_ok: first_ok?, retry_ok: retry_ok?}
      end

    %{
      authority_authorized: Enum.map(rows, &{&1.digest, @gen}),
      iterations: length(rows),
      notes: [{:outcomes, Enum.frequencies_by(rows, &{&1.first_ok, &1.retry_ok})}]
    }
  end
end
