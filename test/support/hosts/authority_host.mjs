#!/usr/bin/env node
// Independent (non-BEAM) host for the SA2A authority court.
//
// This file deliberately shares NO code with ash_a2a. It re-derives the
// authority verdict for a command from the canonical decision envelope
// alone -- the same envelope `AshA2A.Authority.Decision.envelope/3` emits --
// using nothing but Node stdlib. If this host and the BEAM disagree, the
// test that drives it fails.
//
// Usage:
//   node authority_host.mjs <envelope.json> <actuator_log_path>
//   node authority_host.mjs --spec <conformance.json> <actuator_log_path>
//
// In --spec mode the host evaluates every case in the shared conformance
// vector file (authority_decision_conformance.json) with the SAME verdict()
// function and prints one JSON object per line: {"name":...,"verdict":...,
// "code":...,"actuator_calls":...}. That file is the single specification
// both hosts are held to; the BEAM runs the identical vectors through
// AshA2A.Authority.Decision.verdict/1 and the test asserts all three agree
// (BEAM == expected, node == expected, BEAM == node), so the two independent
// implementations cannot silently drift apart again.
//
// The actuator is REAL: on an ADMITTED verdict this host appends one line to
// <actuator_log_path>, creating it. The negative test asserts that file never
// comes into existence; a positive-control envelope in the same test proves
// the write path actually works, so "no file" is a real observation rather
// than a vacuous one.
//
// Prints one line of JSON on stdout:
//   {"verdict":"REFUSED_AUTHORITY","code":"authority_required",
//    "envelope_digest":"<sha256 hex>","actuator_calls":0,"host":"node"}

import { readFileSync, appendFileSync } from "node:fs";
import { createHash } from "node:crypto";

const ENVELOPE_VERSION = "sa2a-authority-decision/1";

// Canonical JSON: recursively key-sorted, no insignificant whitespace.
// Independently implemented; must agree byte-for-byte with
// AshA2A.Authority.Decision.canonical_json/1.
function canonicalJson(value) {
  if (value === null) return "null";
  if (Array.isArray(value)) return "[" + value.map(canonicalJson).join(",") + "]";
  if (typeof value === "object") {
    const keys = Object.keys(value).sort();
    return "{" + keys.map((k) => JSON.stringify(k) + ":" + canonicalJson(value[k])).join(",") + "}";
  }
  if (typeof value === "string") return JSON.stringify(value);
  if (typeof value === "boolean") return value ? "true" : "false";
  if (typeof value === "number") {
    if (!Number.isInteger(value)) throw new Error("non-integer number in envelope");
    return String(value);
  }
  throw new Error("unencodable value in envelope: " + typeof value);
}

function digest(value) {
  return createHash("sha256").update(canonicalJson(value), "utf8").digest("hex");
}

const CLASSIFIED = ["observe", "change", "external_do"];
const CONSEQUENCE_BEARING = ["change", "external_do"];

// Absence never satisfies anything; a blank string is absence with
// punctuation. Mirrors AshA2A.Authority.Decision's present?/1.
function present(value) {
  return typeof value === "string" && value.trim() !== "";
}

// `undefined === undefined` is not a match, it is two absences. Mirrors same?/2.
function same(left, right) {
  return present(left) && present(right) && left === right;
}

// Fails closed on anything unparseable, INCLUDING a missing/unparseable
// evaluated_at: an envelope that does not say when it was evaluated is
// unjudgeable. Expiry is measured against this host's real clock; the
// envelope's own instant is consulted only when it is LATER, so the
// constrained party can close the gate on itself but never hold it open by
// naming a convenient past. Mirrors expired?/2 + expired_at?/2.
function expired(expiresAt, evaluatedAt) {
  if (!present(evaluatedAt)) return true;
  const evaluated = Date.parse(evaluatedAt);
  if (Number.isNaN(evaluated)) return true;
  if (expiresAt === null || expiresAt === undefined) return false;
  if (!present(expiresAt)) return true;
  const expires = Date.parse(expiresAt);
  if (Number.isNaN(expires)) return true;
  return Date.now() > expires || evaluated > expires;
}

function binds(authority, envelope) {
  return (
    same(authority.subject, envelope.principal) &&
    same(authority.capability_id, envelope.capability_id) &&
    !expired(authority.expires_at, envelope.evaluated_at)
  );
}

// The real enforcement point (AshA2A.CommandBus) reads the classification off
// the resource DSL, never off the request. Here it must at minimum agree with
// the DSL-derived attestation the BEAM stamped into the envelope, and an
// UNATTESTED "observe" -- the only classification that skips the authority
// branch entirely -- is never taken on the request's word. Mirrors classify/1.
function classify(envelope) {
  const declared = envelope.consequence;
  const attested = envelope.capability_consequence;

  if (!present(declared) || !CLASSIFIED.includes(declared)) {
    return { code: "consequence_unclassified" };
  }
  if (present(attested) && attested !== declared) {
    return { code: "consequence_unattested" };
  }
  if (!CONSEQUENCE_BEARING.includes(declared) && attested !== declared) {
    return { code: "consequence_unattested" };
  }
  return { consequence: declared };
}

// The whole rule set. Note what is NOT consulted even though the envelope
// carries it: agent, task, command_fingerprint, and the authority's own
// `source` (i.e. how the caller authenticated). RFC S29.
function verdict(envelope) {
  if (!envelope || typeof envelope !== "object" || envelope.envelope_version !== ENVELOPE_VERSION) {
    return { verdict: "REFUSED_AUTHORITY", code: "decision_envelope_unrecognized" };
  }
  if (!present(envelope.principal) || !present(envelope.capability_id)) {
    return { verdict: "REFUSED_AUTHORITY", code: "envelope_incomplete" };
  }
  const classification = classify(envelope);
  if (classification.code) {
    return { verdict: "REFUSED_AUTHORITY", code: classification.code };
  }
  if (!CONSEQUENCE_BEARING.includes(classification.consequence)) {
    return { verdict: "ADMITTED", code: "authority_admitted" };
  }
  const authority = envelope.authority;
  if (authority === null || authority === undefined) {
    return { verdict: "REFUSED_AUTHORITY", code: "authority_required" };
  }
  if (typeof authority !== "object" || Array.isArray(authority) || !binds(authority, envelope)) {
    return { verdict: "REFUSED_AUTHORITY", code: "authority_mismatch" };
  }
  return { verdict: "ADMITTED", code: "authority_admitted" };
}

// The real actuator. Only ever reached past the authority gate.
function actuate(actuatorLogPath, envelope) {
  appendFileSync(
    actuatorLogPath,
    JSON.stringify({ host: "node", capability_id: envelope.capability_id ?? null }) + "\n",
    "utf8",
  );
}

const argv = process.argv.slice(2);

if (argv[0] === "--spec") {
  const [, specPath, actuatorLogPath] = argv;
  if (!specPath || !actuatorLogPath) {
    process.stderr.write("usage: authority_host.mjs --spec <conformance.json> <actuator_log>\n");
    process.exit(2);
  }

  const spec = JSON.parse(readFileSync(specPath, "utf8"));
  for (const testCase of spec.cases) {
    const decision = verdict(testCase.envelope);
    let actuatorCalls = 0;
    if (decision.verdict === "ADMITTED") {
      actuate(actuatorLogPath, testCase.envelope);
      actuatorCalls = 1;
    }
    process.stdout.write(
      JSON.stringify({
        host: "node",
        name: testCase.name,
        verdict: decision.verdict,
        code: decision.code,
        actuator_calls: actuatorCalls,
      }) + "\n",
    );
  }
} else {
  const [envelopePath, actuatorLogPath] = argv;
  if (!envelopePath || !actuatorLogPath) {
    process.stderr.write("usage: authority_host.mjs <envelope.json> <actuator_log_path>\n");
    process.exit(2);
  }

  const envelope = JSON.parse(readFileSync(envelopePath, "utf8"));
  const decision = verdict(envelope);

  let actuatorCalls = 0;
  if (decision.verdict === "ADMITTED") {
    actuate(actuatorLogPath, envelope);
    actuatorCalls = 1;
  }

  process.stdout.write(
    JSON.stringify({
      host: "node",
      verdict: decision.verdict,
      code: decision.code,
      envelope_digest: digest(envelope),
      actuator_calls: actuatorCalls,
    }) + "\n",
  );
}
