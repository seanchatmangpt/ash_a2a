# Starts the REAL AuthorityService.Listener (with a verifying ApproverChannel.Mailbox) for the
# approve-wire tests. Run from authority_service/ with MIX_ENV=test:
#
#     APPROVER_HARNESS_CONFIG=/path/config.json mix run --no-halt \
#       ../sa2a-approver/scripts/authority_listener_harness.exs
#
# config.json: {"dir": d, "approvers": {"alice": "<uncompressed P-256 point, hex>"},
#               "tls": null | {"certfile": f, "keyfile": f, "cacertfile": f}}
# Writes <dir>/ready.json ({"sock": path, "tls_port": n|null, "audience": a}) once
# listening. The mailbox clock is the real clock (approvals must be inside their window).
alias AuthorityService.{ApproverChannel.Mailbox, Listener, TestKit}
alias Sa2aCrypto.{KeyRecord, KeyRef}

cfg = System.fetch_env!("APPROVER_HARNESS_CONFIG") |> File.read!() |> Jason.decode!()
dir = cfg["dir"]

records =
  for {name, hex} <- cfg["approvers"] do
    pub = Base.decode16!(hex, case: :mixed)

    %KeyRecord{
      kid: KeyRef.kid!("ES256", pub),
      alg: "ES256",
      public_key: pub,
      custodian_id: name,
      custody_tier: :i3,
      state: :active,
      revocation_epoch: 4
    }
  end

registry = Sa2aCrypto.Registry.Static.view(records)

{:ok, mb} =
  Mailbox.start_link(
    verify: [
      registry: registry,
      audience: TestKit.authority_audience(),
      skew: 30,
      clock: fn -> System.os_time(:second) end
    ]
  )

ctx =
  TestKit.start_issuer(%{
    dir: dir,
    registry: registry,
    approvers: [],
    policy: TestKit.policy(approvers: Map.keys(cfg["approvers"])),
    channel: {Mailbox, mb}
  })

sock = Path.join(dir, "authority.sock")
{:ok, _} = Listener.start_link(issuer: ctx.issuer, transport: {:unix, sock}, mailbox: mb)

tls_port =
  case cfg["tls"] do
    %{"certfile" => c, "keyfile" => k, "cacertfile" => ca} ->
      {:ok, l} =
        Listener.start_link(
          issuer: ctx.issuer,
          mailbox: mb,
          transport: {:tls, 0, [certfile: c, keyfile: k, cacertfile: ca]}
        )

      Listener.port(l)

    _ ->
      nil
  end

File.write!(
  Path.join(dir, "ready.json"),
  Jason.encode!(%{
    sock: sock,
    tls_port: tls_port,
    audience: TestKit.authority_audience()
  })
)

Process.sleep(:infinity)
