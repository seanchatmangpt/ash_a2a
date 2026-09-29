defmodule Actuator.Wire do
  @moduledoc """
  Transport-independent request handling. Frames are 4-byte-length-prefixed JSON.

      {"op":"execute","effect":<b64url canonical effect bytes>,"certificate":<b64url cert JSON>}
      {"op":"status","effect_instance_id":"..."}
      {"op":"health"}

  Responses: `{"ok":true,"status":"performed|replayed","evidence":{...}}` or
  `{"ok":false,"stage":<check number|"parse"|"config">,"refusal":"<code>"}`.
  There is no operation that reconciles, changes policy or revocation, or takes a path,
  URL, command or module name; those are release/operator actions, not wire actions.
  """
  alias Actuator.{Fence, Store}

  @max_frame 131_072
  def max_frame, do: @max_frame

  @spec handle(GenServer.server(), (-> {:ok, Actuator.Context.t()} | {:error, atom()}), binary()) ::
          binary()
  def handle(store, ctx_fun, frame) when is_binary(frame) and byte_size(frame) <= @max_frame do
    case Jason.decode(frame) do
      {:ok, %{"op" => "execute", "effect" => e, "certificate" => c}}
      when is_binary(e) and is_binary(c) ->
        execute(store, ctx_fun, e, c)

      {:ok, %{"op" => "status", "effect_instance_id" => id}} when is_binary(id) ->
        case Store.status(store, id) do
          {:ok, ev} -> reply(%{"ok" => true, "evidence" => ev})
          :not_found -> refuse("status", :not_found)
        end

      {:ok, %{"op" => "health"}} ->
        reply(%{"ok" => true})

      _ ->
        refuse("parse", :malformed_request)
    end
  end

  def handle(_, _, _), do: refuse("parse", :malformed_request)

  defp execute(store, ctx_fun, e64, c64) do
    with {:ok, eb} <- Sa2aCrypto.Envelope.b64(e64) |> tag(:malformed_request),
         {:ok, cb} <- Sa2aCrypto.Envelope.b64(c64) |> tag(:malformed_request),
         {:ok, ctx} <- ctx_fun.(),
         {:ok, req} <- Fence.parse(eb, cb) do
      case Store.execute(store, ctx, req) do
        {:ok, %{status: s, evidence: ev}} ->
          reply(%{"ok" => true, "status" => Atom.to_string(s), "evidence" => ev})

        {:error, stage, code} ->
          refuse(stage, code)
      end
    else
      {:error, code} when is_atom(code) ->
        refuse(if(code == :config_unavailable, do: "config", else: "parse"), code)
    end
  end

  defp tag({:ok, _} = ok, _), do: ok
  defp tag(_, code), do: {:error, code}

  defp refuse(stage, code),
    do: reply(%{"ok" => false, "stage" => stage, "refusal" => Atom.to_string(code)})

  defp reply(map), do: Jason.encode!(map)
end
