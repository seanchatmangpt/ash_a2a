# Child OS process for the crash court: runs one execute against a real state dir.
# With ACTUATOR_TEST_CRASH=<point> the Store halts the VM (exit 137) at that point.
[config, effect_path, cert_path] = System.argv()
{:ok, ctx} = Actuator.Config.load(config)
{:ok, _} = Actuator.Store.start_link(state_dir: ctx.state_dir, name: Actuator.Store)
res = Actuator.execute(Actuator.Store, ctx, File.read!(effect_path), File.read!(cert_path))
IO.puts("CHILD_RETURNED " <> inspect(res))
