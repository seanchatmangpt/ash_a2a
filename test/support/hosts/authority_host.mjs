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

// Fails closed on anything unparseable.
function expired(expiresAt, evaluatedAt) {
  if (expiresAt === null || expiresAt === undefined) return false;
  if (typeof expiresAt !== "string" || typeof evaluatedAt !== "string") return true;
  const expires = Date.parse(expiresAt);
  const now = Date.parse(evaluatedAt);
  if (Number.isNaN(expires) || Number.isNaN(now)) return true;
  return now > expires;
}

function binds(authority, envelope) {
  return (
    authority.subject === envelope.principal &&
    authority.capability_id === envelope.capability_id &&
    !expired(authority.expires_at, envelope.evaluated_at)
  );
}

// The whole rule set. Note what is NOT consulted even though the envelope
// carries it: agent, task, command_fingerprint, and the authority's own
// `source` (i.e. how the caller authenticated). RFC S29.
function verdict(envelope) {
  if (!envelope || envelope.envelope_version !== ENVELOPE_VERSION) {
    return { verdict: "REFUSED_AUTHORITY", code: "decision_envelope_unrecognized" };
  }
  const consequence = envelope.consequence;
  if (consequence === "observe") {
    return { verdict: "ADMITTED", code: "authority_admitted" };
  }
  if (consequence !== "change" && consequence !== "external_do") {
    return { verdict: "REFUSED_AUTHORITY", code: "consequence_unclassified" };
  }
  const authority = envelope.authority;
  if (authority === null || authority === undefined) {
    return { verdict: "REFUSED_AUTHORITY", code: "authority_required" };
  }
  if (typeof authority !== "object" || !binds(authority, envelope)) {
    return { verdict: "REFUSED_AUTHORITY", code: "authority_mismatch" };
  }
  return { verdict: "ADMITTED", code: "authority_admitted" };
}

const [envelopePath, actuatorLogPath] = process.argv.slice(2);
if (!envelopePath || !actuatorLogPath) {
  process.stderr.write("usage: authority_host.mjs <envelope.json> <actuator_log_path>\n");
  process.exit(2);
}

const envelope = JSON.parse(readFileSync(envelopePath, "utf8"));
const decision = verdict(envelope);

let actuatorCalls = 0;
if (decision.verdict === "ADMITTED") {
  // The real actuator. Only ever reached past the authority gate.
  appendFileSync(
    actuatorLogPath,
    JSON.stringify({ host: "node", capability_id: envelope.capability_id ?? null }) + "\n",
    "utf8",
  );
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
