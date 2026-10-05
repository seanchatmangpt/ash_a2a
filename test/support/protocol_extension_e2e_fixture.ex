# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Test.ProtocolExtensionE2EFixture.Passport do
  @moduledoc """
  Real `AshA2A.Protocol.Extension` fixture for the extension-negotiation e2e
  court (`test/ash_a2a_protocol_extension_e2e_test.exs`): a `required: true`,
  data-only profile extension used to pin the `ExtensionSupportRequiredError`
  (-32008) negotiation path over the real plug.

  Lane F1 fix-forward (v26.10.3): moved OUT of the test's own `.exs` script
  into `test/support/` (same module name, byte-for-byte the same behaviour).
  A script-defined module's load state can transiently read `:nofile` under
  the full parallel suite, which flaked `Code.ensure_loaded!/1` inside
  `AshA2A.Protocol.Plug.init/1`; a `test/support` module compiles to a real
  on-disk `.beam` on the code path, so `ensure_loaded` can always admit it.
  Implements no hooks — only `declaration/1` — which also proves the
  behaviour's documented default activation path (no `activate/3` => always
  `{:ok, nil}`).
  """

  @behaviour AshA2A.Protocol.Extension

  @uri "https://test.ash_a2a.example/ext/passport/v1"

  @doc "The stable URI advertised by this extension."
  @spec uri() :: String.t()
  def uri, do: @uri

  @impl AshA2A.Protocol.Extension
  def declaration(_state) do
    %AshA2A.Protocol.AgentExtension{
      uri: @uri,
      description: "Test fixture: required passport extension",
      required: true
    }
  end
end
