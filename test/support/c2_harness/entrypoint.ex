# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule C2Harness.Entrypoint do
  @moduledoc """
  The actuator through its PRODUCTION entrypoint (`MIX_ENV=prod mix run --no-halt`, where
  `Actuator.Application` builds the Store and the UDS/mTLS listeners from `ACTUATOR_CONFIG`):
  everything else in the court runs the instrumented host script, so this is the check that
  the shipped boot path itself refuses, serves and has no crash points.

    * E01 no `ACTUATOR_CONFIG`: boot refusal, non-zero exit, no listener
    * E02 the shipped boot path serves one legitimate effect (one authorized ledger entry),
      refuses a certificate from an unregistered key, and returns evidence on replay
    * E03 `ACTUATOR_TEST_CRASH=after_perform` set in the production environment does nothing:
      the crash points are compiled out of the prod build (the request completes and the
      process stays up)
  """
  alias C2Harness.{Attack, Attacker, Env, Fleet}

  defp m(attck, capec, atlas \\ ["AML.T0053"]), do: %{attck: attck, capec: capec, atlas: atlas}

  def attacks do
    [
      %Attack{
        id: "C2C-E01",
        title: "production entrypoint without ACTUATOR_CONFIG refuses to boot",
        s26: ["policy-option removal"],
        expect: ["boot_refused"],
        mapping: m(["T1562"], ["CAPEC-176"]),
        run: fn env ->
          case Fleet.start_prod_actuator(env.fleet, config: false) do
            {:error, {:exited_before_ready, status, _}} when status != 0 ->
              Env.note(env, "boot_refused")

            other ->
              Env.note(env, "boot_unexpected:" <> inspect(other))
          end

          %{authorized: []}
        end
      },
      %Attack{
        id: "C2C-E02",
        title:
          "production entrypoint: one authorized effect performed, forged certificate refused, replay returns evidence",
        s26: ["forged certificate", "replay of a valid certificate"],
        expect: ["performed", "unknown_kid", "replayed"],
        mapping: m(["T1606", "T1550"], ["CAPEC-196", "CAPEC-60"]),
        run: fn env ->
          {:ok, _} = Fleet.start_prod_actuator(env.fleet)
          :ok = Env.wait_healthy(env)
          l = Env.issue!(env, Env.effect())
          Env.submit(env, l.effect, l.cert)
          Env.submit(env, l.effect, l.cert)
          eb = Env.bytes(Env.effect())
          sigs = for _ <- 1..2, do: %{key: Attacker.own_key(), nonce: Attacker.nonce()}
          Env.submit(env, eb, Attacker.forge_cert(env.cp, eb, sigs))
          %{authorized: [l.digest]}
        end
      },
      %Attack{
        id: "C2C-E03",
        title:
          "crash points are compiled out of the production build (ACTUATOR_TEST_CRASH is inert)",
        s26: ["worker crash before DO"],
        expect: ["performed", "crash_points_compiled_out"],
        mapping: m(["T1562"], ["CAPEC-176"]),
        run: fn env ->
          {:ok, _} =
            Fleet.start_prod_actuator(env.fleet, env: [{"ACTUATOR_TEST_CRASH", "after_perform"}])

          :ok = Env.wait_healthy(env)
          l = Env.issue!(env, Env.effect())
          r = Env.submit(env, l.effect, l.cert)

          if r[:status] == "performed" and Fleet.actuator_alive?(env.fleet),
            do: Env.note(env, "crash_points_compiled_out")

          %{authorized: [l.digest]}
        end
      }
    ]
  end
end
