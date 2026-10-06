# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ClientHTTPJSONInteropTest.Resource do
  @moduledoc """
  Real fixture resource, private to this test file: a single real `:read`
  skill on a real ETS-backed Ash resource, so dispatch has exactly one skill
  and needs no `:skill` metadata.
  """

  use Ash.Resource,
    domain: AshA2A.ClientHTTPJSONInteropTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  attributes do
    uuid_primary_key(:id)
  end

  actions do
    defaults([:read])
  end

  a2a do
    skill(:echo, :read)
  end
end

defmodule AshA2A.ClientHTTPJSONInteropTest.Domain do
  @moduledoc "Real fixture domain for the resource above."

  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(AshA2A.ClientHTTPJSONInteropTest.Resource)
  end
end

defmodule AshA2A.ClientHTTPJSONInteropTest.EchoAgent do
  @moduledoc "Real `AshA2A.Agent` GenServer over the fixture resource above."

  use AshA2A.Agent,
    resource_or_domain: AshA2A.ClientHTTPJSONInteropTest.Resource,
    name: "client_http_json_echo_agent"
end

defmodule AshA2A.ClientHTTPJSONInteropTest.PushReceiver do
  @moduledoc false
  # Real webhook receiver: forwards (method, body) to the test pid and answers
  # 200. Its loopback URL is what the real `WebhookPolicy` admits.
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, %{test: test}) do
    {:ok, body, conn} = read_body(conn)
    send(test, {:webhook, conn.method, body})
    send_resp(conn, 200, "")
  end
end

defmodule AshA2A.ClientHTTPJSONInteropTest.AuthPipeline do
  @moduledoc false
  # Real composite plug: a real `AshA2A.Protocol.Plug.Auth` (Bearer) in front
  # of the real `AshA2A.Transport.HTTPJSON` binding carrying an
  # `:extended_card` provider — the stack an operator deploys for the
  # authenticated extended card over the REST binding.
  @behaviour Plug

  @impl Plug
  def init(opts) when is_map(opts), do: opts

  def init(opts) do
    rest =
      AshA2A.Transport.HTTPJSON.init(
        agent: Keyword.fetch!(opts, :agent),
        base_url: "http://127.0.0.1/a2a",
        extended_card: Keyword.get(opts, :extended_card)
      )

    auth =
      AshA2A.Protocol.Plug.Auth.init(
        schemes: %{"bearer_auth" => %AshA2A.Protocol.SecurityScheme.HTTPAuth{scheme: "bearer"}},
        verify: Keyword.fetch!(opts, :verify)
      )

    %{auth: auth, rest: rest}
  end

  @impl Plug
  def call(conn, %{auth: auth, rest: rest}) do
    conn
    |> AshA2A.Protocol.Plug.Auth.call(auth)
    |> then(fn conn ->
      if conn.halted, do: conn, else: AshA2A.Transport.HTTPJSON.call(conn, rest)
    end)
  end
end

defmodule AshA2A.ClientHTTPJSONInteropTest do
  @moduledoc """
  REAL interop court for the `AshA2A.Protocol.Client` HTTP+JSON mode
  (`transport: :http_json`): a real Bandit server running the real
  `AshA2A.Transport.HTTPJSON` binding on a loopback ephemeral port, a real
  supervised `use AshA2A.Agent` GenServer over a real ETS Ash resource, and
  real `Req` calls driving discover/send/list/get/cancel, the
  push-notification-config CRUD and the authenticated extended card end to end
  through the client. Zero mocks.
  """

  use ExUnit.Case, async: false

  @moduletag :serial_shard

  alias AshA2A.A2ATransport.PushConfigStore
  alias AshA2A.ClientHTTPJSONInteropTest.AuthPipeline
  alias AshA2A.ClientHTTPJSONInteropTest.PushReceiver
  alias AshA2A.Protocol.{Client, PushNotificationConfig, Task}
  alias AshA2A.Test.{AgentSupervisorCase, EphemeralHttp}

  alias AshA2A.Transport.HTTPJSON, as: Binding

  @push_secret "client-httpjson-push-signing-secret"

  setup do
    agent = AshA2A.ClientHTTPJSONInteropTest.EchoAgent

    {_sup, _registry} =
      AgentSupervisorCase.start_supervised_agents!(__MODULE__, [agent])

    plug_opts =
      Binding.init(agent: agent, base_url: "http://127.0.0.1/fixture")

    server = EphemeralHttp.start!({Binding, plug_opts})

    %{server: server, client: Client.new(server.base_url, transport: :http_json)}
  end

  # -- fixtures --------------------------------------------------------------------

  # Real push stack: a real `AshA2A.A2ATransport` (whose PushConfigStore the
  # REST routes write through), a real loopback webhook receiver whose URL the
  # real `WebhookPolicy` admits, and a second real HTTPJSON binding instance
  # with push notifications enabled.
  defp start_push_stack! do
    agent = AshA2A.ClientHTTPJSONInteropTest.EchoAgent
    transport = :"a2a_transport_client_httpjson_#{System.unique_integer([:positive])}"

    start_supervised!(
      {AshA2A.A2ATransport,
       name: transport,
       push: [
         allow_http: true,
         allow_cidrs: ["127.0.0.1/32"],
         signing_secret: @push_secret,
         max_attempts: 3,
         base_backoff_ms: 10
       ]}
    )

    receiver = EphemeralHttp.start!({PushReceiver, %{test: self()}})

    server =
      EphemeralHttp.start!(
        {Binding,
         Binding.init(
           agent: agent,
           base_url: "http://127.0.0.1/fixture",
           transport: transport,
           push_notifications: true
         )}
      )

    %{
      transport: transport,
      hook: receiver.base_url <> "/hook",
      client: Client.new(server.base_url, transport: :http_json)
    }
  end

  # Extended-card provider (real public 2-arity function, the provider
  # contract) and real bearer verifier.
  def admin_card_provider(%{identity: %{sub: sub}}, card) do
    skill = %{"id" => "admin", "name" => "Admin", "description" => "for #{sub}", "tags" => []}
    {:ok, Map.update!(card, "skills", &(&1 ++ [skill]))}
  end

  defp verify(_scheme, "valid-token-42", _conn), do: {:ok, %{sub: "alice"}}

  # Real authed server: the Auth pipeline in front of the binding, with an
  # `:extended_card` provider when one is given (nil = none configured).
  defp start_authed_client!(provider) do
    opts =
      AuthPipeline.init(
        agent: AshA2A.ClientHTTPJSONInteropTest.EchoAgent,
        extended_card: provider,
        verify: &verify/3
      )

    server = EphemeralHttp.start!({AuthPipeline, opts})
    Client.new(server.base_url, transport: :http_json)
  end

  # -- discovery -----------------------------------------------------------------

  test "discover/2 fetches the real agent card (binding-independent)", %{server: server} do
    assert {:ok, card} = Client.discover(server.base_url)
    assert is_binary(card.name)
    assert is_binary(card.url)
    assert card.skills != []
  end

  # -- send_message: POST /message:send ------------------------------------------

  test "send_message/3 posts to /message:send and decodes the completed task", %{
    client: client
  } do
    assert {:ok, %Task{} = task} = Client.send_message(client, "go")
    assert "tsk-" <> _ = task.id
    assert task.status.state == :completed
    assert [%AshA2A.Protocol.Artifact{parts: [_]}] = task.artifacts
  end

  test "send_message/3 decodes a bare agent Message answer", %{client: client} do
    msg = AshA2A.Protocol.Message.new_user("hi")
    assert {:ok, _task_or_message} = Client.send_message(client, msg)
  end

  test "send_message/3 continuing a terminal task maps the 400 to :invalid_params", %{
    client: client
  } do
    {:ok, %Task{} = task} = Client.send_message(client, "first")

    assert {:error, :invalid_params} =
             Client.send_message(client, "second", task_id: task.id)
  end

  # -- get_task: GET /tasks/{id} ---------------------------------------------------

  test "get_task/3 reads the task back from /tasks/{id}", %{client: client} do
    {:ok, sent} = Client.send_message(client, "round trip")

    assert {:ok, %Task{} = fetched} = Client.get_task(client, sent.id)
    assert fetched.id == sent.id
    assert fetched.status.state == :completed
    assert fetched.context_id == sent.context_id
  end

  test "get_task/3 forwards :history_length as the historyLength query param", %{
    client: client
  } do
    {:ok, sent} = Client.send_message(client, "history")

    assert {:ok, truncated} = Client.get_task(client, sent.id, history_length: 0)
    assert truncated.history == []

    assert {:ok, with_history} = Client.get_task(client, sent.id)
    assert with_history.history != []
  end

  test "get_task/3 on an unknown task maps the 404 to :task_not_found", %{client: client} do
    assert {:error, :task_not_found} = Client.get_task(client, "tsk-does-not-exist")
  end

  # -- cancel_task: POST /tasks/{id}:cancel ----------------------------------------

  test "cancel_task/3 on an unknown task maps the 404 to :task_not_found", %{client: client} do
    assert {:error, :task_not_found} = Client.cancel_task(client, "tsk-nope")
  end

  test "cancel_task/3 on a terminal task maps the 400 to :task_not_cancelable", %{
    client: client
  } do
    {:ok, %Task{} = task} = Client.send_message(client, "cancel me")

    assert {:error, :task_not_cancelable} = Client.cancel_task(client, task.id)
  end

  # -- operations with no §5.3 REST route ------------------------------------------

  test "stream/resubscribe refuse with {:transport_unsupported, op}", %{
    client: client
  } do
    assert {:error, {:transport_unsupported, :stream_message}} =
             Client.stream_message(client, "go")

    assert {:error, {:transport_unsupported, :resubscribe}} =
             Client.resubscribe(client, "tsk-x")
  end

  test "jsonrpc-mode clients refuse list_tasks/get_extended_card with {:transport_unsupported, op}", %{
    server: server
  } do
    json_client = Client.new(server.base_url)

    assert {:error, {:transport_unsupported, :list_tasks}} = Client.list_tasks(json_client)

    assert {:error, {:transport_unsupported, :get_extended_card}} =
             Client.get_extended_card(json_client)
  end

  # -- list_tasks: GET /tasks -------------------------------------------------------

  # GET /tasks is owner-scoped (SEC-01): a listing only ever contains tasks the
  # VERIFIED caller owns (anonymous callers never list), so these tests run
  # through the real auth pipeline with a real bearer identity.
  @list_headers [{"authorization", "Bearer valid-token-42"}]

  test "list_tasks/2 lists the verified caller's tasks from GET /tasks and decodes the page envelope", %{
    client: _client
  } do
    client = start_authed_client!(nil)

    {:ok, %Task{} = a} = Client.send_message(client, "list one", headers: @list_headers)
    {:ok, %Task{} = b} = Client.send_message(client, "list two", headers: @list_headers)

    assert {:ok, page} = Client.list_tasks(client, headers: @list_headers)
    assert %Task{} = hd(page.tasks)
    ids = Enum.map(page.tasks, & &1.id)
    assert a.id in ids
    assert b.id in ids
    assert page.total_size >= 2
  end

  test "list_tasks/2 paginates via :page_size/:page_token and filters by :context_id", %{
    client: _client
  } do
    client = start_authed_client!(nil)
    headers = @list_headers

    {:ok, %Task{} = a} = Client.send_message(client, "page one", headers: headers)
    {:ok, _b} = Client.send_message(client, "page two", headers: headers)

    assert {:ok, page1} = Client.list_tasks(client, page_size: 1, headers: headers)
    assert length(page1.tasks) == 1
    assert page1.total_size >= 2
    assert is_binary(page1.next_page_token) and page1.next_page_token != ""

    assert {:ok, page2} = Client.list_tasks(client, page_size: 1, page_token: page1.next_page_token, headers: headers)
    assert [%Task{} = other] = page2.tasks
    refute other.id == hd(page1.tasks).id

    assert {:ok, filtered} = Client.list_tasks(client, context_id: a.context_id, headers: headers)
    assert Enum.all?(filtered.tasks, &(&1.context_id == a.context_id))
    assert a.id in Enum.map(filtered.tasks, & &1.id)
  end

  test "list_tasks/2 negative: a non-wire :status maps the 400 ErrorInfo to :invalid_params", %{
    client: client
  } do
    assert {:error, :invalid_params} = Client.list_tasks(client, status: "NOT_A_TASK_STATE")
  end

  # -- push-notification-config CRUD over the REST routes ----------------------------

  test "set_push_config/3 stores through the real PushConfigStore; webhook credentials are write-only", %{
    client: client
  } do
    {:ok, %Task{} = task} = Client.send_message(client, "push me")
    %{transport: transport, hook: hook, client: push_client} = start_push_stack!()

    config = %PushNotificationConfig{
      task_id: task.id,
      url: hook,
      token: "tok-gl-1",
      authentication: %{scheme: "Bearer", credentials: "s3cret-gl-1"}
    }

    assert {:ok, %PushNotificationConfig{} = stored} = Client.set_push_config(push_client, config)
    assert is_binary(stored.id) and stored.id != ""
    assert stored.url == hook
    assert stored.task_id == task.id
    assert stored.token == "tok-gl-1"

    # The echo never carries the webhook credentials...
    refute Map.has_key?(stored.authentication || %{}, :credentials)

    # ...but they really were stored in the real store.
    {:ok, in_store} = PushConfigStore.get(AshA2A.A2ATransport.push_store_name(transport), task.id, stored.id)

    assert in_store.authentication == %{"scheme" => "Bearer", "credentials" => "s3cret-gl-1"}
  end

  test "set_push_config/3 negative: an unknown task maps the 404 ErrorInfo to :task_not_found" do
    %{hook: hook, client: push_client} = start_push_stack!()

    config = %PushNotificationConfig{task_id: "tsk-does-not-exist", url: hook}

    assert {:error, :task_not_found} = Client.set_push_config(push_client, config)
  end

  test "set_push_config/3 negative: push disabled answers 400 -32003 -> :push_notification_not_supported", %{
    client: client
  } do
    {:ok, %Task{} = task} = Client.send_message(client, "no push here")

    config = %PushNotificationConfig{
      task_id: task.id,
      url: "https://example.com/webhook"
    }

    assert {:error, :push_notification_not_supported} = Client.set_push_config(client, config)
  end

  test "get_push_config/4 reads the config back from GET /tasks/{id}/pushNotificationConfig/{cid}", %{
    client: client
  } do
    {:ok, %Task{} = task} = Client.send_message(client, "get cfg")
    %{hook: hook, client: push_client} = start_push_stack!()

    config = %PushNotificationConfig{task_id: task.id, url: hook, token: "tok-gl-2"}
    {:ok, stored} = Client.set_push_config(push_client, config)

    assert {:ok, %PushNotificationConfig{} = fetched} =
             Client.get_push_config(push_client, task.id, stored.id)

    assert fetched.id == stored.id
    assert fetched.task_id == task.id
    assert fetched.url == hook
    assert fetched.token == "tok-gl-2"
  end

  test "get_push_config/4 negative: a missing config maps the 400 ErrorInfo to :invalid_params", %{
    client: client
  } do
    {:ok, %Task{} = task} = Client.send_message(client, "missing cfg")
    %{client: push_client} = start_push_stack!()

    assert {:error, :invalid_params} =
             Client.get_push_config(push_client, task.id, "cfg-never-registered")
  end

  test "list_push_configs/3 lists the task's configs from GET /tasks/{id}/pushNotificationConfig", %{
    client: client
  } do
    {:ok, %Task{} = task} = Client.send_message(client, "list cfgs")
    %{hook: hook, client: push_client} = start_push_stack!()

    config = %PushNotificationConfig{task_id: task.id, url: hook, token: "tok-gl-3"}
    {:ok, stored} = Client.set_push_config(push_client, config)

    assert {:ok, [%PushNotificationConfig{} = only]} =
             Client.list_push_configs(push_client, task.id)

    assert only.id == stored.id
    assert only.url == hook
  end

  test "list_push_configs/3 negative: an unknown task maps the 404 ErrorInfo to :task_not_found" do
    %{client: push_client} = start_push_stack!()

    assert {:error, :task_not_found} = Client.list_push_configs(push_client, "tsk-does-not-exist")
  end

  test "delete_push_config/4 deletes via DELETE /tasks/{id}/pushNotificationConfig/{cid}", %{
    client: client
  } do
    {:ok, %Task{} = task} = Client.send_message(client, "delete cfg")
    %{hook: hook, client: push_client} = start_push_stack!()

    config = %PushNotificationConfig{task_id: task.id, url: hook}

    {:ok, stored} = Client.set_push_config(push_client, config)

    assert :ok = Client.delete_push_config(push_client, task.id, stored.id)
    assert {:ok, []} = Client.list_push_configs(push_client, task.id)

    # Idempotent per TCK PUSH-DEL-002 (fb2e844d): re-deleting an already-deleted
    # config answers success, never an error — a delete outcome, not addressing.
    assert :ok = Client.delete_push_config(push_client, task.id, stored.id)
  end

  test "delete_push_config/4 negative: an unknown task maps the 404 ErrorInfo to :task_not_found" do
    %{client: push_client} = start_push_stack!()

    assert {:error, :task_not_found} =
             Client.delete_push_config(push_client, "tsk-does-not-exist", "cfg-1")
  end

  # -- get_extended_card: POST /agent -------------------------------------------------

  test "get_extended_card/2 POSTs /agent with auth and decodes the provider-extended card", %{
    client: _client
  } do
    ext_client = start_authed_client!(&__MODULE__.admin_card_provider/2)

    assert {:ok, card} =
             Client.get_extended_card(ext_client,
               headers: [{"authorization", "Bearer valid-token-42"}]
             )

    admin = Enum.find(card.skills, &(&1.id == "admin"))
    assert admin.description == "for alice"

    # The public card from the same server never carries the admin skill: the
    # extension exists only per verified call.
    {:ok, public} = Client.discover(ext_client)
    refute "admin" in Enum.map(public.skills, & &1.id)
  end

  test "get_extended_card/2 negative: no credentials maps the 401 to {:http_error, 401, body}", %{
    client: _client
  } do
    ext_client = start_authed_client!(&__MODULE__.admin_card_provider/2)

    assert {:error, {:http_error, 401, body}} = Client.get_extended_card(ext_client)
    assert %{"error" => "Unauthorized"} = body
  end

  test "get_extended_card/2 negative: no provider maps the 400 ErrorInfo to :extended_card_not_configured", %{
    client: _client
  } do
    ext_client = start_authed_client!(nil)

    assert {:error, :extended_card_not_configured} =
             Client.get_extended_card(ext_client,
               headers: [{"authorization", "Bearer valid-token-42"}]
             )
  end

  # -- client construction ---------------------------------------------------------

  test "new/2 rejects an unknown transport", %{server: server} do
    assert_raise ArgumentError, ~r/invalid :transport/, fn ->
      Client.new(server.base_url, transport: :carrier_pigeon)
    end
  end

  test "default transport stays :jsonrpc", %{server: server} do
    assert %Client{transport: :jsonrpc} = Client.new(server.base_url)
  end
end
