if Code.ensure_loaded?(Req) do
  defmodule AshA2A.Protocol.Client.Interceptor do
    @moduledoc """
    Behaviour for `AshA2A.Protocol.Client` request/response interceptors.

    Pass modules with the `:interceptors` option of `Client.new/2` (or
    `Client.from_card/2`). They run as `Req` steps on every request the
    client issues, in list order for requests and in list order for
    responses.

        defmodule MyApp.TraceInterceptor do
          @behaviour AshA2A.Protocol.Client.Interceptor

          @impl true
          def before_request(req), do: Req.Request.put_header(req, "x-trace", "abc")

          @impl true
          def after_response(_req, response), do: response
        end

        client = Client.new(url, interceptors: [MyApp.TraceInterceptor])

    Both callbacks are optional; a module implementing only one is valid.
    Streaming responses (`into: :self`) reach `after_response/2` with an
    unconsumed `Req.Response.Async` body.
    """

    @callback before_request(Req.Request.t()) :: Req.Request.t()
    @callback after_response(Req.Request.t(), Req.Response.t()) :: Req.Response.t()

    @optional_callbacks before_request: 1, after_response: 2

    @doc false
    @spec attach(Req.Request.t(), [module()]) :: Req.Request.t()
    def attach(req, []), do: req

    def attach(req, interceptors) when is_list(interceptors) do
      Enum.each(interceptors, &Code.ensure_loaded/1)

      req
      |> Req.Request.append_request_steps(
        a2a_interceptors_before: fn request -> run_before(request, interceptors) end
      )
      |> Req.Request.append_response_steps(
        a2a_interceptors_after: fn {request, response} ->
          {request, run_after(request, response, interceptors)}
        end
      )
    end

    defp run_before(request, interceptors) do
      Enum.reduce(interceptors, request, fn mod, acc ->
        if function_exported?(mod, :before_request, 1), do: mod.before_request(acc), else: acc
      end)
    end

    defp run_after(request, response, interceptors) do
      Enum.reduce(interceptors, response, fn mod, acc ->
        if function_exported?(mod, :after_response, 2),
          do: mod.after_response(request, acc),
          else: acc
      end)
    end
  end
end
