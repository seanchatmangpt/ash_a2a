defmodule AshA2A.Protocol do
  @moduledoc """
  Elixir implementation of the Agent-to-Agent (A2A) protocol.

  A2A provides a behaviour-based agent framework where agents are local
  GenServer processes. Use `AshA2A.Protocol.call/3` and `AshA2A.Protocol.stream/3` to interact
  with agents.

  ## Quick Start

      # Define an agent
      defmodule MyAgent do
        use AshA2A.Protocol.Agent,
          name: "my-agent",
          description: "Does things"

        @impl AshA2A.Protocol.Agent
        def handle_message(message, _context) do
          {:reply, [AshA2A.Protocol.Part.Text.new("Got: \#{AshA2A.Protocol.Message.text(message)}")]}
        end
      end

      # Start and call it
      {:ok, _pid} = MyAgent.start_link()
      {:ok, task} = AshA2A.Protocol.call(MyAgent, "hello")
  """

  @doc """
  Returns the encoded agent card for a local agent.

  Fetches the card via GenServer and encodes it using
  `AshA2A.Protocol.JSON.encode_agent_card/2`. This is useful for serving agent
  cards from custom endpoints (e.g., a Phoenix controller) when you
  set `agent_card_path: false` on `AshA2A.Protocol.Plug`.

  ## Options

  - `:base_url` — the public URL of the agent endpoint (required)
  - All other options are forwarded to `AshA2A.Protocol.JSON.encode_agent_card/2`

  ## Examples

      AshA2A.Protocol.get_agent_card(MyAgent, base_url: "https://example.com/a2a")
      # => %{"name" => ..., "url" => "https://example.com/a2a", ...}
  """
  @spec get_agent_card(GenServer.server(), keyword()) :: map()
  def get_agent_card(agent, opts) do
    {base_url, encode_opts} = Keyword.pop!(opts, :base_url)
    card = GenServer.call(agent, :get_agent_card)
    AshA2A.Protocol.JSON.encode_agent_card(card, [{:url, base_url} | encode_opts])
  end

  @doc """
  Sends a message to a local agent and returns the resulting task.

  The `agent` can be a module name (registered GenServer) or a PID.
  The `message` can be a string, an `AshA2A.Protocol.Message.t()`, or a list of parts.

  Returns `{:ok, task}`, or `{:ok, message}` when the agent replies
  `{:message, parts}` — a bare `AshA2A.Protocol.Message.t()` with no task behind it.

  ## Options

  - `:context_id` — associate the message with a conversation context
  - `:task_id` — continue an existing task (must be in a non-terminal state)
  - `:timeout` — GenServer call timeout in ms (default: `60_000`)

  ## Examples

      AshA2A.Protocol.call(MyAgent, "hello")
      AshA2A.Protocol.call(MyAgent, message, context_id: "ctx-123")

      # Multi-turn: continue an input_required task
      {:ok, task} = AshA2A.Protocol.call(MyAgent, "order pizza")
      {:ok, task} = AshA2A.Protocol.call(MyAgent, "large", task_id: task.id)
  """
  @spec call(GenServer.server(), String.t() | AshA2A.Protocol.Message.t(), keyword()) ::
          {:ok, AshA2A.Protocol.Task.t() | AshA2A.Protocol.Message.t()} | {:error, term()}
  def call(agent, message, opts \\ [])

  def call(agent, message, opts) when is_binary(message) do
    call(agent, AshA2A.Protocol.Message.new_user(message), opts)
  end

  def call(agent, %AshA2A.Protocol.Message{} = message, opts) do
    {timeout, opts} = Keyword.pop(opts, :timeout, 60_000)
    meta = %{agent: agent, streaming: false}

    :telemetry.span([:a2a, :agent, :call], meta, fn ->
      case GenServer.call(agent, {:message, message, opts}, timeout) do
        {:ok, %AshA2A.Protocol.Message{} = reply} = result ->
          {result,
           Map.merge(meta, %{
             message_id: reply.message_id,
             context_id: reply.context_id
           })}

        {:ok, task} = result ->
          {result,
           Map.merge(meta, %{
             task_id: task.id,
             status: task.status.state,
             context_id: task.context_id
           })}

        {:error, reason} = result ->
          {result, Map.put(meta, :error, reason)}
      end
    end)
  end

  @doc """
  Sends a message to a streaming agent and returns the stream.

  The agent's `handle_message/2` must return `{:stream, enumerable}`.
  The returned stream is lazy — the caller must consume it.

  An agent that replies `{:message, parts}` answers out-of-band instead:
  the call returns `{:ok, message}` with no task and no stream.

  ## Options

  - `:context_id` — associate the message with a conversation context
  - `:timeout` — GenServer call timeout in ms (default: `60_000`)

  ## Examples

      AshA2A.Protocol.stream(MyAgent, "research topic")
      |> Stream.each(&process/1)
      |> Stream.run()
  """
  @spec stream(GenServer.server(), String.t() | AshA2A.Protocol.Message.t(), keyword()) ::
          {:ok, AshA2A.Protocol.Task.t(), Enumerable.t()} | {:ok, AshA2A.Protocol.Message.t()} | {:error, term()}
  def stream(agent, message, opts \\ [])

  def stream(agent, message, opts) when is_binary(message) do
    stream(agent, AshA2A.Protocol.Message.new_user(message), opts)
  end

  def stream(agent, %AshA2A.Protocol.Message{} = message, opts) do
    {timeout, opts} = Keyword.pop(opts, :timeout, 60_000)
    meta = %{agent: agent, streaming: true}

    :telemetry.span([:a2a, :agent, :call], meta, fn ->
      case GenServer.call(agent, {:message, message, opts}, timeout) do
        {:ok, %AshA2A.Protocol.Task{metadata: %{stream: enum}} = task} ->
          result = {:ok, task, enum}

          {result,
           Map.merge(meta, %{
             task_id: task.id,
             status: task.status.state,
             context_id: task.context_id
           })}

        {:ok, %AshA2A.Protocol.Message{} = agent_message} = result ->
          {result,
           Map.merge(meta, %{
             message_id: agent_message.message_id,
             context_id: agent_message.context_id
           })}

        {:ok, task} ->
          result = {:error, {:not_streaming, task}}
          {result, Map.put(meta, :error, {:not_streaming, task})}

        {:error, reason} = result ->
          {result, Map.put(meta, :error, reason)}
      end
    end)
  end
end
