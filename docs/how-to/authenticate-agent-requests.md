# How to authenticate inbound A2A requests and thread identity into your Ash actions

This guide wires a real `A2A.Plug.Auth` in front of a real `A2A.Plug`, so a Bearer
credential on an inbound A2A request becomes `context.actor`/`context.tenant` inside
your Ash action. It is based directly on the working end-to-end test
`test/ash_a2a_plug_auth_test.exs` and the trust-boundary code in
`lib/ash_a2a/context_resolver.ex` — every snippet below matches that real code.

## The trust boundary you need to understand first

`AshA2A.ContextResolver.from_a2a_message/4` never reads `actor`/`tenant` out of the
inbound `A2A.Message`'s own `metadata` field. That field is unauthenticated JSON-RPC
request body content — any caller can put `%{"actor" => %{"id" => "admin"}}` in it.
The only path an actor/tenant can take into your action is:

1. `A2A.Plug.Auth` verifies a real credential and stores the result in
   `conn.private[:a2a][:auth]`.
2. `A2A.Plug` merges that into the call's `metadata["a2a.auth"]`.
3. `AshA2A.Agent.__dispatch__` reads `metadata["a2a.auth"][:identity]` and passes it
   to `AshA2A.Dispatcher.dispatch/5` as `auth_identity`.
4. `AshA2A.ContextResolver.from_a2a_message/4` sets `context.actor` to that
   `auth_identity` verbatim, and `context.tenant` to `auth_identity[:tenant]` (or the
   string-keyed `"tenant"`), or `nil` if the caller never wired auth at all.

If you skip `A2A.Plug.Auth`, `context.actor` and `context.tenant` are always `nil` —
dispatch fails closed rather than trusting anything from the wire.

## 1. Define a `:verify` callback

`A2A.Plug.Auth.init/1` takes the security schemes your agent declares and a `:verify`
function of arity 3 (`scheme, credential, conn`). Return `{:ok, identity_map}` for a
valid credential, `{:error, reason}` otherwise:

```elixir
defp verify_callback("bearer_auth", "valid-token-42", _conn) do
  {:ok, %{id: "user-42", tenant: "acme"}}
end

defp verify_callback(_scheme, _credential, _conn), do: {:error, "invalid token"}
```

In production this looks up the bearer token in your real token store instead of
matching a literal string. The returned map's `:tenant` (or `"tenant"`) key is what
`ContextResolver` extracts as `context.tenant`; the whole map becomes `context.actor`.

## 2. Build the plug pipeline

Declare your security schemes, initialize `A2A.Plug.Auth` with them and your verify
callback, then chain into `A2A.Plug` pointed at your `AshA2A.Agent` module:

```elixir
@schemes %{"bearer_auth" => %A2A.SecurityScheme.HTTPAuth{scheme: "bearer"}}

auth_opts =
  A2A.Plug.Auth.init(
    schemes: @schemes,
    verify: &verify_callback/3
  )

plug_opts =
  A2A.Plug.init(
    agent: AuthProbeAgent,
    base_url: "http://localhost:4000/a2a"
  )

conn
|> A2A.Plug.Auth.call(auth_opts)
|> then(fn conn ->
  if conn.halted, do: conn, else: A2A.Plug.call(conn, plug_opts)
end)
```

`A2A.Plug.Auth.call/2` halts the conn with a `401` and `%{"error" => "Unauthorized"}`
body before `A2A.Plug` ever runs, both when the `Authorization` header is missing and
when `verify_callback/3` returns `{:error, _}` — checking `conn.halted` before chaining
into `A2A.Plug` is required, exactly as shown above.

## 3. Read identity in the Ash action

Nothing special is required in the action itself — `context.actor` and
`context.tenant` are already populated by the time your action's `run/2` (or any
other Ash action type) executes:

```elixir
action :whoami, :map do
  run(fn _input, context ->
    {:ok, %{actor: context.actor, tenant: context.tenant}}
  end)
end
```

With the `verify_callback/3` above and a request bearing
`Authorization: Bearer valid-token-42`, this action returns
`%{actor: %{id: "user-42", tenant: "acme"}, tenant: "acme"}` — the real assertion made
by `test/ash_a2a_plug_auth_test.exs`.

## 4. The `:ambiguous_skill` gotcha

`AshA2A.Agent.__dispatch__` picks a skill automatically only when the resource
exposes exactly one public action. `AshA2A.Info.capability_index/1` returning:

* zero skills → `{:error, {:no_skill, resource_or_domain}}`
* exactly one skill → dispatches to it implicitly
* two or more skills → `{:error, {:ambiguous_skill, resource_or_domain}}`

A resource with `defaults([:read])` plus one custom action (like `AuthProbe`'s
`:whoami` above) already has two public actions, so it hits the ambiguous case. Fix it
by setting `metadata["skill"]` explicitly on the outbound `A2A.Message`:

```elixir
message = %{A2A.Message.new_user([A2A.Part.Data.new(%{})]) | metadata: %{"skill" => "whoami"}}
```

`AshA2A.Agent.resolve_skill_name/2` reads `metadata["skill"]` (via
`AshA2A.MetadataKey.get/2`, so either the atom or string key works) before ever
falling back to the single-skill default, so an explicit skill name always
disambiguates regardless of how many public actions the resource has. Note that
`"skill"` here is a routing directive read from message metadata deliberately — it is
not `actor`/`tenant`, and `ContextResolver` never touches it.
