defmodule AuthorityService.WireTest do
  use ExUnit.Case, async: true
  alias AuthorityService.{Listener, TestKit}
  import TestKit

  defp frame(term),
    do:
      (
        b = Jason.encode!(term)
        <<byte_size(b)::32, b::binary>>
      )

  defp call(path, payload) do
    {:ok, s} = :gen_tcp.connect({:local, path}, 0, [:binary, active: false, packet: :raw])
    :ok = :gen_tcp.send(s, payload)
    r = :gen_tcp.recv(s, 4, 2000)

    out =
      case r do
        {:ok, <<len::32>>} ->
          {:ok, body} = :gen_tcp.recv(s, len, 2000)
          Jason.decode!(body)

        other ->
          other
      end

    :gen_tcp.close(s)
    out
  end

  test "typed unix-socket wire: issue, refuse, size bound" do
    ctx = start_issuer()
    sock = Path.join(ctx.dir, "a.sock")
    {:ok, _} = Listener.start_link(issuer: ctx.issuer, transport: {:unix, sock}, max_bytes: 4096)

    e = effect()
    d = digest(effect_bytes(e))
    apps = for n <- ~w(alice bob), do: approval(signer_named(ctx, n), d)

    assert %{"ok" => true, "certificate" => %{"envelope" => _, "message" => _}} =
             call(sock, frame(Map.put(request(e, apps), "op", "issue")))

    assert %{"ok" => false, "refusal" => "already_issued"} =
             call(sock, frame(Map.put(request(e, apps), "op", "issue")))

    assert %{"ok" => false, "refusal" => "insufficient_approvals"} =
             call(
               sock,
               frame(
                 Map.put(
                   request(effect(%{"idem" => "z"}), []),
                   "op",
                   "issue"
                 )
               )
             )

    assert %{"ok" => false, "refusal" => "malformed_request"} = call(sock, frame("nope"))
    assert %{"ok" => false, "refusal" => "unknown_op"} = call(sock, frame(%{"op" => "exec"}))

    # size bound: a declared length above max_bytes is refused without reading the body
    assert %{"ok" => false, "refusal" => "request_too_large"} =
             call(sock, <<1_000_000::32, "x">>)

    mode = File.stat!(sock).mode |> Bitwise.band(0o777)
    assert Bitwise.band(mode, 0o007) == 0
  end
end
