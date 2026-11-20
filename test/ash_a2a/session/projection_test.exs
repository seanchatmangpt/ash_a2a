# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Session.ProjectionTest do
  use ExUnit.Case, async: false

  alias AshA2A.Session.{Hibernate, Projection}

  @fixture Path.expand("../../support/session_projection_fixture.ttl", __DIR__)

  setup do
    host = :"sess4_host_#{System.unique_integer([:positive])}"
    start_supervised!({AshGraphLaw.Host, name: host})
    {:ok, host: host}
  end

  test "fixture graph projected through the real Host yields the literal quad count", %{
    host: host
  } do
    assert AshGraphLaw.Host.available?(host)

    assert {:ok, %{quads: 3, nquads: nquads, id: id}} =
             Projection.project_graph(host, File.read!(@fixture), "turtle")

    assert is_binary(id) and id != ""
    assert nquads |> String.split("\n", trim: true) |> length() == 3
  end

  test "byte-identical input projects to identical results", %{host: host} do
    text = File.read!(@fixture)
    assert {:ok, first} = Projection.project_graph(host, text, "turtle")
    assert {:ok, second} = Projection.project_graph(host, text, "turtle")
    assert first == second
  end

  test "a projecting session projects to 3 quads and is stable across runs", %{host: host} do
    {:ok, pid} = Hibernate.start_link("conn-proj", 60_000)
    assert {:error, {:not_projecting, :hydrating}} = Projection.project(pid, host)
    assert {:ok, :projecting} = Hibernate.send_event(pid, :hydrated)

    assert {:ok, %{quads: 3} = first} = Projection.project(pid, host)
    assert {:ok, ^first} = Projection.project(pid, host)
  end
end
