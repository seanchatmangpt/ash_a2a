# Child OS process for the truncation/anchor courts: boots the Store on a real state dir and
# runs one execute. A boot refusal prints BOOT_REFUSED <reason> and exits 3.
Process.flag(:trap_exit, true)
[config, effect_path, cert_path] = System.argv()
{:ok, ctx} = Actuator.Config.load(config)

case Actuator.Store.start_link(state_dir: ctx.state_dir, name: Actuator.Store) do
  {:ok, _} ->
    res = Actuator.execute(Actuator.Store, ctx, File.read!(effect_path), File.read!(cert_path))
    IO.puts("CHILD_RETURNED " <> inspect(res))

  {:error, reason} ->
    IO.puts("BOOT_REFUSED " <> inspect(reason))
    System.halt(3)
end
