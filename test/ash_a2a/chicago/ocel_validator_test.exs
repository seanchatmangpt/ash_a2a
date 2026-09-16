defmodule AshA2A.Chicago.OcelValidatorTest do
  @moduledoc """
  Qualifies `AshA2A.Chicago.Ocel.Validator` and the `SA2A-OCEL` court,
  Chicago style: the court end-to-end over the real `AshA2A.CommandBus`, a
  real `AshA2A.Chicago.Observer`, durable artifacts on disk, the real
  validator deciding, and the independent `AshA2A.Chicago.Query` consumer
  corroborating every verdict. Narrow tests exercise each validator guard over
  real files in `tmp_dir`, one defect at a time, so deleting a guard makes its
  test fail (§22).

  `async: false` -- `Context.stimulus/3` attribution and the observer's
  telemetry handlers see every event the node emits.
  """

  use ExUnit.Case, async: false

  alias AshA2A.Chicago.{Context, Observer, Result, Runner, StandingReceipt}
  alias AshA2A.Chicago.Courts.OcelValidity
  alias AshA2A.Chicago.Ocel.{Log, Mapping, Validator}

  @moduletag :tmp_dir

  @negatives ~w(002 003 004 005 006 007 008 009 010 013 014 015 016 017 018 019 020 021)
  @positives ~w(001 011 012)

  describe "SA2A-OCEL end-to-end through the runner" do
    test "every falsifier is killed, every positive control passes, all OCEL-corroborated",
         %{tmp_dir: dir} do
      assert {:ok, run} = Runner.run(courts: [OcelValidity], profile: :core, evidence_dir: dir)

      by_id = Map.new(run.results, &{&1.falsifier_id, &1})
      assert map_size(by_id) == length(@negatives) + length(@positives)
      assert Enum.sort(Map.keys(by_id)) == Enum.sort(Enum.map(OcelValidity.falsifiers(), & &1.id))

      for n <- @negatives do
        result = by_id["SA2A-OCEL-" <> n]

        assert result.verdict == :falsifier_killed,
               "SA2A-OCEL-#{n}: #{result.verdict} #{result.detail} | #{result.ocel_detail}"

        assert result.attempt_observed? == true
        assert result.ocel_corroborated? == true, "SA2A-OCEL-#{n}: #{result.ocel_detail}"
        assert Result.counts_as_pass?(result)
      end

      for n <- @positives do
        result = by_id["SA2A-OCEL-" <> n]

        assert result.verdict == :positive_control_passed,
               "SA2A-OCEL-#{n}: #{result.verdict} #{result.detail} | #{result.ocel_detail}"

        assert result.ocel_corroborated? == true, "SA2A-OCEL-#{n}: #{result.ocel_detail}"
      end

      # The run's own artifact is validated by the same independent validator
      # and the standing receipt binds that result (§16, §104).
      assert run.ocel_validation.status == :valid, inspect(run.ocel_validation.report)
      receipt = JSON.decode!(File.read!(Path.join(dir, "standing_receipt.json")))
      assert :ok = StandingReceipt.verify_digest(receipt)
      assert receipt["evidence"]["ocel_valid"] == true
      assert receipt["evidence"]["ocel_validator"] == inspect(Validator)
      assert receipt["results"]["falsifiers_survived"] == 0
      assert receipt["results"]["falsifiers_killed"] == length(@negatives)
      assert receipt["results"]["positive_controls_passed"] == length(@positives)

      validation = JSON.decode!(File.read!(Path.join(dir, "ocel_validation.json")))
      assert validation["status"] == "valid"
      assert validation["report"]["artifact_sha256"] == run.ocel.sha256
      assert validation["report"]["validator"]["name"] == inspect(Validator)

      # The base evidence is real SUT process history: object-centric (§107),
      # and the refused command wrote no row (independent reader).
      base = by_id["SA2A-OCEL-001"]
      assert base.evidence["refused_row_absent"] == true

      assert Enum.all?(
               ~w(capability command principal),
               &(&1 in base.evidence["admission_object_types"])
             )

      assert base.evidence["reply_code"] == ":authority_required"
    end
  end

  describe "validate_file/1 over a real producer artifact" do
    test "a real observer artifact validates and its report is JSON-safe and content-addressed",
         %{tmp_dir: dir} do
      path = observer_artifact(dir)
      bytes = File.read!(path)

      assert {:ok, report} = Validator.validate_file(path)
      assert report["valid"] == true
      assert report["serialization"] == "json"
      assert report["artifact_sha256"] == sha(bytes)
      assert report["artifact_bytes"] == byte_size(bytes)
      assert report["validator"]["name"] == "AshA2A.Chicago.Ocel.Validator"
      assert report["validator"]["version"] == "1.0.0"
      assert {:ok, _, _} = DateTime.from_iso8601(report["validated_at"])
      assert report["counts"]["events"] >= 3
      assert report["counts"]["event_object_relationships"] > 0
      assert report["errors"] == []
      assert JSON.decode!(JSON.encode!(report)) == report
    end

    test "each guard refuses exactly its defect with a coded, located error", %{tmp_dir: dir} do
      doc = base_doc()

      cases = [
        {"dangling_object_reference", "/events/0/relationships/0/objectId",
         put_in(
           doc,
           ["events", Access.at(0), "relationships", Access.at(0), "objectId"],
           "o-missing"
         )},
        {"dangling_object_reference", "/objects/0/relationships/0/objectId",
         put_in(
           doc,
           ["objects", Access.at(0), "relationships", Access.at(0), "objectId"],
           "o-missing"
         )},
        {"undeclared_attribute", "/events/0/attributes/1/name",
         update_in(
           doc,
           ["events", Access.at(0), "attributes"],
           &(&1 ++ [%{"name" => "x", "value" => "y"}])
         )},
        {"attribute_value_type_mismatch", "/events/0/attributes/0/value",
         put_in(doc, ["events", Access.at(0), "attributes", Access.at(0), "value"], "12x")},
        {"invalid_time", "/events/0/time",
         put_in(doc, ["events", Access.at(0), "time"], "2026-13-45T99:99:99Z")},
        {"invalid_time", "/objects/0/attributes/0/time",
         put_in(doc, ["objects", Access.at(0), "attributes", Access.at(0), "time"], "yesterday")},
        {"duplicate_object_id", "/objects/2/id", update_in(doc, ["objects"], &(&1 ++ [hd(&1)]))},
        {"duplicate_event_id", "/events/1/id", put_in(doc, ["events", Access.at(1), "id"], "e1")},
        {"missing_top_level_key", "/objects", Map.delete(doc, "objects")},
        {"undeclared_event_type", "/events/0/type",
         put_in(doc, ["events", Access.at(0), "type"], "nope")},
        {"undeclared_object_type", "/objects/1/type",
         put_in(doc, ["objects", Access.at(1), "type"], "nope")},
        {"invalid_qualifier", "/events/0/relationships/0/qualifier",
         put_in(doc, ["events", Access.at(0), "relationships", Access.at(0), "qualifier"], 7)},
        {"invalid_attribute_type", "/eventTypes/0/attributes/0/type",
         put_in(doc, ["eventTypes", Access.at(0), "attributes", Access.at(0), "type"], "datetime")},
        {"duplicate_type_name", "/objectTypes/2/name",
         update_in(doc, ["objectTypes"], &(&1 ++ [%{"name" => "order", "attributes" => []}]))},
        {"duplicate_attribute_declaration", "/eventTypes/0/attributes/1/name",
         update_in(
           doc,
           ["eventTypes", Access.at(0), "attributes"],
           &(&1 ++ [%{"name" => "seq", "type" => "string"}])
         )},
        {"duplicate_event_attribute", "/events/0/attributes/1/name",
         update_in(
           doc,
           ["events", Access.at(0), "attributes"],
           &(&1 ++ [%{"name" => "seq", "value" => 2}])
         )},
        {"empty_identifier", "/events/0/id", put_in(doc, ["events", Access.at(0), "id"], "")},
        {"missing_required_field", "/events/0/time",
         update_in(doc, ["events", Access.at(0)], &Map.delete(&1, "time"))},
        {"invalid_type", "/events", Map.put(doc, "events", %{})}
      ]

      # Removing `objects` necessarily also leaves event relationships dangling;
      # every other case must be diagnosed by exactly one guard.
      cascades = %{"missing_top_level_key" => ["dangling_object_reference"]}

      for {{code, path, corrupted}, i} <- Enum.with_index(cases) do
        file = write!(dir, "case-#{i}.json", JSON.encode!(corrupted))
        assert {:error, report} = Validator.validate_file(file), "case #{i} (#{code}) validated"
        assert report["valid"] == false

        assert Enum.any?(report["errors"], &(&1["code"] == code and &1["path"] == path)),
               "case #{i}: expected #{code}@#{path}, got #{inspect(report["errors"])}"

        codes = report["errors"] |> Enum.map(& &1["code"]) |> Enum.uniq()
        assert codes -- [code | Map.get(cascades, code, [])] == [], "case #{i}: #{inspect(codes)}"
      end
    end

    test "the fixture baseline is valid (so every case above isolates one guard)", %{tmp_dir: dir} do
      assert {:ok, %{"error_count" => 0}} =
               Validator.validate_file(write!(dir, "base.json", JSON.encode!(base_doc())))
    end

    test "non-JSON, non-object and unreadable artifacts are refused", %{tmp_dir: dir} do
      assert {:error, %{"errors" => [%{"code" => "non_json"}]} = r} =
               Validator.validate_file(write!(dir, "trunc.json", ~s({"objectTypes": [)))

      assert is_binary(r["artifact_sha256"])

      assert {:error, %{"errors" => [%{"code" => "non_json"}]}} =
               Validator.validate_file(write!(dir, "bin.json", <<0xFF, 0xFE, 0x00>>))

      assert {:error, %{"errors" => [%{"code" => "not_an_object"}]}} =
               Validator.validate_file(write!(dir, "array.json", "[]"))

      assert {:error,
              %{"errors" => [%{"code" => "unreadable_artifact"}], "artifact_sha256" => nil}} =
               Validator.validate_file(Path.join(dir, "absent.json"))
    end

    test "typed and all-string value serializations both validate; offset-less time warns",
         %{tmp_dir: dir} do
      doc =
        base_doc()
        |> put_in(["events", Access.at(0), "attributes", Access.at(0), "value"], "1")
        |> put_in(["objects", Access.at(0), "attributes", Access.at(0), "value"], "9.5")
        |> put_in(["events", Access.at(1), "time"], "2026-09-16T10:00:00")

      assert {:ok, report} =
               Validator.validate_file(write!(dir, "strings.json", JSON.encode!(doc)))

      assert [%{"code" => "time_without_offset", "count" => 1}] = report["warnings"]

      wrong_bool =
        put_in(base_doc(), ["objects", Access.at(1), "attributes", Access.at(0), "value"], "yes")

      assert {:error, %{"errors" => [%{"code" => "attribute_value_type_mismatch"}]}} =
               Validator.validate_file(write!(dir, "bool.json", JSON.encode!(wrong_bool)))

      float_as_int =
        put_in(base_doc(), ["events", Access.at(0), "attributes", Access.at(0), "value"], 1.5)

      assert {:error, %{"errors" => [%{"code" => "attribute_value_type_mismatch"}]}} =
               Validator.validate_file(write!(dir, "float.json", JSON.encode!(float_as_int)))
    end
  end

  describe "supports?/2 evidence completeness (§106)" do
    test "supported, incomplete and invalid are distinct outcomes", %{tmp_dir: dir} do
      path = write!(dir, "base.json", JSON.encode!(base_doc()))

      assert {:ok, %{"supported" => true, "missing" => [], "outcome" => "supported"}} =
               Validator.supports?(path, ["place", {"ship", %{"carrier" => "dhl"}}])

      assert {:error, %{"outcome" => "incomplete", "missing" => missing}} =
               Validator.supports?(path, ["place", {"ship", %{"carrier" => "ups"}}, "refund"])

      assert Enum.map(missing, & &1["activity"]) == ["ship", "refund"]

      bad = write!(dir, "bad.json", "not json")

      assert {:error, %{"outcome" => "invalid", "supported" => false, "missing" => [_]}} =
               Validator.supports?(bad, ["place"])
    end

    test "emits validated and completeness telemetry from the deciding boundary", %{tmp_dir: dir} do
      path = write!(dir, "base.json", JSON.encode!(base_doc()))
      ref = make_ref()
      parent = self()
      handler = {__MODULE__, ref}

      :ok =
        :telemetry.attach_many(
          handler,
          Validator.telemetry_events(),
          fn event, measurements, meta, _ -> send(parent, {ref, event, measurements, meta}) end,
          nil
        )

      try do
        {:error, _} = Validator.supports?(path, ["refund"])

        assert_received {^ref, [:ash_a2a, :chicago, :ocel, :validated], %{error_count: 0},
                         %{outcome: :valid, artifact_sha256: sha}}

        assert_received {^ref, [:ash_a2a, :chicago, :ocel, :completeness], %{missing_count: 1},
                         %{outcome: :incomplete, missing: "refund", artifact_sha256: ^sha}}
      after
        :telemetry.detach(handler)
      end
    end
  end

  describe "independence and the observer defect" do
    test "SA2A-OCEL is discovered for :core and every falsifier declares both predicates" do
      assert OcelValidity in AshA2A.Chicago.courts_for(:core)
      falsifiers = OcelValidity.falsifiers()
      assert length(falsifiers) == length(@negatives) + length(@positives)

      for f <- falsifiers do
        assert f.court_id == "SA2A-OCEL"
        assert String.starts_with?(f.id, "SA2A-OCEL-")
        assert f.attempt_predicate != nil, f.id
        assert f.outcome_predicate != nil, f.id
      end

      assert Enum.map(Enum.filter(falsifiers, &(&1.kind == :positive_control)), & &1.id) ==
               Enum.map(@positives, &("SA2A-OCEL-" <> &1))
    end

    test "the validator references no producer or consumer module (§15-§16)" do
      {:ok, {_, [atoms: atoms]}} = :beam_lib.chunks(:code.which(Validator), [:atoms])
      referenced = MapSet.new(atoms, fn {_, atom} -> atom end)

      for forbidden <- [Log, Observer, Mapping, AshA2A.Chicago.Query, AshA2A.Chicago.Json] do
        refute MapSet.member?(referenced, forbidden), "validator references #{inspect(forbidden)}"
      end
    end

    test "two admitted mappings for one telemetry event still yield unique event ids", %{
      tmp_dir: dir
    } do
      event = [:ash_a2a, :chicago, :ocel_validator_test, :probe]
      a = Mapping.new!(event: event, activity: "probe.a", source: __MODULE__)
      b = Mapping.new!(event: event, activity: "probe.b", source: __MODULE__)
      {:ok, observer} = Observer.start_link(run_id: "overlap", mappings: [a, b])

      :telemetry.execute(event, %{}, %{})
      :telemetry.execute(event, %{}, %{})
      {:ok, flush} = Observer.flush(observer, dir)
      Observer.stop(observer)

      doc = JSON.decode!(File.read!(flush.path))
      ids = Enum.map(doc["events"], & &1["id"])
      assert length(ids) == 4
      assert ids == Enum.uniq(ids)
      assert {:ok, _} = Validator.validate_file(flush.path)
    end
  end

  # --- helpers -------------------------------------------------------------------

  # A real observer artifact of real telemetry (a mapped probe event inside a
  # real stimulus), flushed to disk.
  defp observer_artifact(dir) do
    event = [:ash_a2a, :chicago, :ocel_validator_test, :sut]

    mapping =
      Mapping.new!(
        event: event,
        activity: "sut.step",
        source: __MODULE__,
        objects: fn _m, meta ->
          [{"order", meta[:order], "order"}, {"item", meta[:item], "item"}]
        end,
        attributes: fn m, meta -> %{"n" => m[:n], "ok" => meta[:ok], "ratio" => m[:ratio]} end
      )

    {:ok, observer} = Observer.start_link(run_id: "validator-unit", mappings: [mapping])
    [f | _] = OcelValidity.falsifiers()

    ctx = %Context{
      run_id: "validator-unit",
      profile: :core,
      subject: nil,
      evidence_dir: dir,
      observer: observer
    }

    Context.stimulus(ctx, f, fn ->
      :telemetry.execute(event, %{n: 1, ratio: 0.5}, %{order: "o1", item: "i1", ok: true})
      :telemetry.execute(event, %{n: 2, ratio: 1.5}, %{order: "o1", item: "i2", ok: false})
    end)

    {:ok, flush} = Observer.flush(observer, Path.join(dir, "observer"))
    Observer.stop(observer)
    flush.path
  end

  # Minimal hand-checked OCEL 2.0 document exercising every construct the
  # validator judges. Used only to isolate one guard per case -- never as a
  # process-conformance oracle (§14).
  defp base_doc do
    %{
      "objectTypes" => [
        %{"name" => "order", "attributes" => [%{"name" => "price", "type" => "float"}]},
        %{"name" => "item", "attributes" => [%{"name" => "fragile", "type" => "boolean"}]}
      ],
      "eventTypes" => [
        %{"name" => "place", "attributes" => [%{"name" => "seq", "type" => "integer"}]},
        %{
          "name" => "ship",
          "attributes" => [
            %{"name" => "carrier", "type" => "string"},
            %{"name" => "eta", "type" => "time"}
          ]
        }
      ],
      "objects" => [
        %{
          "id" => "o1",
          "type" => "order",
          "attributes" => [%{"name" => "price", "time" => "1970-01-01T00:00:00Z", "value" => 9.5}],
          "relationships" => [%{"objectId" => "i1", "qualifier" => "contains"}]
        },
        %{
          "id" => "i1",
          "type" => "item",
          "attributes" => [
            %{"name" => "fragile", "time" => "2026-09-16T09:00:00+02:00", "value" => true}
          ]
        }
      ],
      "events" => [
        %{
          "id" => "e1",
          "type" => "place",
          "time" => "2026-09-16T09:00:00.123456Z",
          "attributes" => [%{"name" => "seq", "value" => 1}],
          "relationships" => [
            %{"objectId" => "o1", "qualifier" => "order"},
            %{"objectId" => "i1", "qualifier" => "item"}
          ]
        },
        %{
          "id" => "e2",
          "type" => "ship",
          "time" => "2026-09-16T10:00:00Z",
          "attributes" => [
            %{"name" => "carrier", "value" => "dhl"},
            %{"name" => "eta", "value" => "2026-09-17T10:00:00Z"}
          ],
          "relationships" => [%{"objectId" => "o1", "qualifier" => "order"}]
        }
      ]
    }
  end

  defp write!(dir, name, bytes) do
    path = Path.join(dir, name)
    File.write!(path, bytes)
    path
  end

  defp sha(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
