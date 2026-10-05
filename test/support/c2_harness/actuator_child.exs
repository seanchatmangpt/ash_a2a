# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

# C2 compromise court: instrumented Actuator host (RFC-SA2A-006 s26 harness).
#
# Run as `cd actuator && MIX_ENV=test mix run --no-halt --no-compile ... <this file>` in its
# OWN OS process with its own MIX_BUILD_ROOT and state dir. It starts the real
# `Actuator.Store` and the real UDS/mTLS wire listeners from the operator-pinned
# ACTUATOR_CONFIG (the same modules `Actuator.Application` starts in a release); the only
# additions are the two court hooks below, both compiled/activated ONLY through this script:
#
#   * crash points: `Actuator.Store` compiles `fault/1` only under `fault_hook: true`
#     (test env). This script polls `<C2_CTL_DIR>/crash.point` and mirrors it into the
#     ACTUATOR_TEST_CRASH OS env var the Store reads at every fault point, so a court can
#     arm a crash point in a running actuator without a reboot.
#   * mutants: ACTUATOR_MUTANT_SKIP="3,4" | "all" recompiles `Actuator.Fence` from its OWN
#     source with those check numbers force-skipped (the documented `opts[:skip]` seam of
#     `Actuator.Fence.run/4`, which `Actuator.Store` never passes). The patch asserts its
#     needle occurs exactly once, so a refactor of fence.ex cannot silently turn a mutant
#     into a no-op: the child refuses to boot instead.
Code.eval_file(Path.join(__DIR__, "watchdog.exs"))
cfg = System.fetch_env!("ACTUATOR_CONFIG")
ctl = System.fetch_env!("C2_CTL_DIR")

mutant_skip =
  case System.get_env("ACTUATOR_MUTANT_SKIP") do
    nil -> []
    "" -> []
    "all" -> Enum.to_list(1..16)
    csv -> csv |> String.split(",", trim: true) |> Enum.map(&String.to_integer/1)
  end

if mutant_skip != [] do
  src_path = Path.join(File.cwd!(), "lib/actuator/fence.ex")
  src = File.read!(src_path)
  needle = "skip = Keyword.get(opts, :skip, [])"

  unless length(String.split(src, needle)) == 2 do
    IO.puts("C2_MUTANT_REFUSED needle_not_unique")
    System.halt(3)
  end

  patched = String.replace(src, needle, needle <> " ++ " <> inspect(mutant_skip))
  Code.put_compiler_option(:ignore_module_conflict, true)
  Code.compile_string(patched, "fence_mutant.ex")
end

# Rendezvous fault points (default for the court): `Actuator.Store.fault/1` normally halts the
# VM (exit 137) at the armed point. Recompiling the Store from its own source with the halt
# replaced by "write <ctl>/at_fault, then block forever" lets the HARNESS deliver a real
# `kill -9` to the process while it sits exactly at the fault point. Both needles must occur
# exactly once or the child refuses to boot (a refactor cannot silently disable the hook).
if System.get_env("C2_FAULT_RENDEZVOUS") == "1" do
  store_path = Path.join(File.cwd!(), "lib/actuator/store.ex")
  store_src = File.read!(store_path)
  halt_needle = ":erlang.halt(137, flush: false)"
  hook_needle = "@fault Application.compile_env(:actuator, :fault_hook, false)"

  unless length(String.split(store_src, halt_needle)) == 2 and
           length(String.split(store_src, hook_needle)) == 2 do
    IO.puts("C2_FAULT_HOOK_REFUSED needle_not_unique")
    System.halt(3)
  end

  rendezvous =
    "(File.write!(Path.join(System.fetch_env!(\"C2_CTL_DIR\"), \"at_fault\"), Atom.to_string(point)); " <>
      "Process.sleep(:infinity))"

  patched_store =
    store_src
    |> String.replace(halt_needle, rendezvous)
    |> String.replace(hook_needle, "@fault true")

  Code.put_compiler_option(:ignore_module_conflict, true)
  Code.compile_string(patched_store, "store_rendezvous.ex")
end

{:ok, ctx} = Actuator.Config.load(cfg)
raw = cfg |> File.read!() |> Jason.decode!()
wire = raw["wire"] || %{}
ctx_fun = fn -> Actuator.Config.load(cfg) end

{:ok, _} = Actuator.Store.start_link(state_dir: ctx.state_dir, name: Actuator.Store)

if p = wire["uds_path"] do
  {:ok, _} = Actuator.Wire.UDS.start_link(path: p, store: Actuator.Store, ctx_fun: ctx_fun)
end

if t = wire["tls"] do
  {:ok, _} =
    Actuator.Wire.TLS.start_link(
      store: Actuator.Store,
      ctx_fun: ctx_fun,
      port: t["port"],
      certfile: t["certfile"],
      keyfile: t["keyfile"],
      cacertfile: t["cacertfile"]
    )
end

crash_file = Path.join(ctl, "crash.point")

spawn(fn ->
  loop = fn loop ->
    case File.read(crash_file) do
      {:ok, point} when point != "" -> System.put_env("ACTUATOR_TEST_CRASH", String.trim(point))
      _ -> System.delete_env("ACTUATOR_TEST_CRASH")
    end

    Process.sleep(15)
    loop.(loop)
  end

  loop.(loop)
end)

IO.puts(
  "C2_READY " <>
    Jason.encode!(%{
      role: "actuator",
      os_pid: System.pid(),
      node_alive: Node.alive?(),
      mutant_skip: mutant_skip,
      fault_rendezvous: System.get_env("C2_FAULT_RENDEZVOUS") == "1",
      otp: :erlang.system_info(:otp_release) |> List.to_string()
    })
)

Process.sleep(:infinity)
