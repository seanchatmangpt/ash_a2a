#!/usr/bin/env node
// SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
//
// SPDX-License-Identifier: MIT
//
// Chromium WebCrypto channel-bind host for R-04 (Chicago court).
// Real Google Chrome + CDP. No mocks of SubtleCrypto / IndexedDB.
//
// Protocol: JSON lines on stdin → JSON lines on stdout.
//   {"op":"boot"}
//   {"op":"sign","connId":"...","challengeB64":"..."}
//   {"op":"clear_ambient"}   // cookies + sessionStorage (IndexedDB kept)
//   {"op":"probe_export"}
//   {"op":"shutdown"}

import http from "node:http";
import { spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const DOMAIN = "ASHA2A-R04-CHANNEL-BIND-v1";

function chromeBinary() {
  for (const c of [
    process.env.CHROME_BIN,
    "/usr/bin/google-chrome-stable",
    "/usr/bin/google-chrome",
    "/usr/local/bin/google-chrome",
  ]) {
    if (c && fs.existsSync(c)) return c;
  }
  throw new Error("chrome_not_found");
}

function getJson(url) {
  return new Promise((resolve, reject) => {
    http
      .get(url, (res) => {
        let d = "";
        res.on("data", (c) => (d += c));
        res.on("end", () => {
          try {
            resolve(JSON.parse(d));
          } catch (e) {
            reject(e);
          }
        });
      })
      .on("error", reject);
  });
}

async function waitPort(port, ms = 15000) {
  const start = Date.now();
  while (Date.now() - start < ms) {
    try {
      await getJson(`http://127.0.0.1:${port}/json/version`);
      return;
    } catch {
      await new Promise((r) => setTimeout(r, 100));
    }
  }
  throw new Error(`chrome_cdp_timeout:${port}`);
}

class Cdp {
  constructor(wsUrl) {
    this.ws = new WebSocket(wsUrl);
    this.id = 0;
    this.pending = new Map();
    this.ws.onmessage = (ev) => {
      const msg = JSON.parse(ev.data);
      if (msg.id && this.pending.has(msg.id)) {
        const { resolve, reject } = this.pending.get(msg.id);
        this.pending.delete(msg.id);
        if (msg.error) reject(new Error(JSON.stringify(msg.error)));
        else resolve(msg.result);
      }
    };
  }

  ready() {
    return new Promise((resolve, reject) => {
      this.ws.onopen = resolve;
      this.ws.onerror = reject;
    });
  }

  send(method, params = {}) {
    const id = ++this.id;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.ws.send(JSON.stringify({ id, method, params }));
    });
  }

  close() {
    try {
      this.ws.close();
    } catch {
      /* ignore */
    }
  }
}

const PAGE_HTML = `<!DOCTYPE html><html><body><pre id="out">boot</pre>
<script>
window.__R04_HOST__ = {
  domain: ${JSON.stringify(DOMAIN)},
  async boot() {
    const kp = await crypto.subtle.generateKey(
      { name: "ECDSA", namedCurve: "P-256" },
      false,
      ["sign", "verify"]
    );
    let exportRefused = false;
    let exportError = null;
    try {
      await crypto.subtle.exportKey("pkcs8", kp.privateKey);
    } catch (e) {
      exportRefused = true;
      exportError = e.name || String(e);
    }
    const pub = await crypto.subtle.exportKey("raw", kp.publicKey);
    await new Promise((resolve, reject) => {
      const req = indexedDB.open("asha2a-r04-channel-bind", 1);
      req.onupgradeneeded = () => req.result.createObjectStore("keys");
      req.onsuccess = () => {
        const db = req.result;
        const tx = db.transaction("keys", "readwrite");
        tx.objectStore("keys").put(kp.privateKey, "session");
        tx.oncomplete = () => resolve();
        tx.onerror = () => reject(tx.error);
      };
      req.onerror = () => reject(req.error);
    });
    this._pub = pub;
    return {
      ok: true,
      extractable: kp.privateKey.extractable,
      exportRefused,
      exportError,
      pubB64: btoa(String.fromCharCode(...new Uint8Array(pub))),
      idbStored: true
    };
  },
  async loadKey() {
    return new Promise((resolve, reject) => {
      const req = indexedDB.open("asha2a-r04-channel-bind", 1);
      req.onsuccess = () => {
        const db = req.result;
        const tx = db.transaction("keys", "readonly");
        const g = tx.objectStore("keys").get("session");
        g.onsuccess = () => resolve(g.result);
        g.onerror = () => reject(g.error);
      };
      req.onerror = () => reject(req.error);
    });
  },
  signingInput(connId, challengeBytes) {
    const enc = new TextEncoder();
    const domain = enc.encode(this.domain);
    const conn = enc.encode(String(connId));
    const out = new Uint8Array(domain.length + 1 + conn.length + 1 + challengeBytes.length);
    out.set(domain, 0);
    out[domain.length] = 0;
    out.set(conn, domain.length + 1);
    out[domain.length + 1 + conn.length] = 0;
    out.set(challengeBytes, domain.length + 1 + conn.length + 1);
    return out;
  },
  async sign(connId, challengeB64) {
    const key = await this.loadKey();
    if (!key) throw new Error("idb_key_missing");
    const challenge = Uint8Array.from(atob(challengeB64), (c) => c.charCodeAt(0));
    const input = this.signingInput(connId, challenge);
    const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, input);
    return {
      ok: true,
      sigB64: btoa(String.fromCharCode(...new Uint8Array(sig))),
      extractable: key.extractable
    };
  },
  clearAmbient() {
    document.cookie.split(";").forEach((c) => {
      const n = c.split("=")[0].trim();
      if (n) document.cookie = n + "=;expires=Thu, 01 Jan 1970 00:00:00 GMT;path=/";
    });
    sessionStorage.clear();
    // Deliberately leave IndexedDB intact — that is the channel-bind store.
    return {
      ok: true,
      cookie: document.cookie,
      sessionStorageLength: sessionStorage.length
    };
  },
  async probeExport() {
    const key = await this.loadKey();
    try {
      await crypto.subtle.exportKey("pkcs8", key);
      return { ok: true, exportRefused: false };
    } catch (e) {
      return { ok: true, exportRefused: true, exportError: e.name || String(e) };
    }
  }
};
</script></body></html>`;

let state = {
  chrome: null,
  udd: null,
  pageFile: null,
  cdp: null,
  port: null,
};

function reply(obj) {
  process.stdout.write(JSON.stringify(obj) + "\n");
}

async function boot() {
  if (state.cdp) return { ok: false, error: "already_booted" };

  const udd = fs.mkdtempSync(path.join(os.tmpdir(), "r04-chrome-"));
  const pageFile = path.join(udd, "court.html");
  fs.writeFileSync(pageFile, PAGE_HTML);
  const port = 9300 + Math.floor(Math.random() * 400);
  const chrome = spawn(
    chromeBinary(),
    [
      "--headless=new",
      "--disable-gpu",
      "--no-sandbox",
      "--disable-dev-shm-usage",
      `--user-data-dir=${udd}`,
      "--no-first-run",
      "--no-default-browser-check",
      `--remote-debugging-port=${port}`,
      "about:blank",
    ],
    { stdio: ["ignore", "ignore", "pipe"] }
  );

  state = { chrome, udd, pageFile, cdp: null, port };
  await waitPort(port);

  const targets = await getJson(`http://127.0.0.1:${port}/json/list`);
  const page = targets.find((t) => t.type === "page");
  if (!page) throw new Error("no_page_target");

  const cdp = new Cdp(page.webSocketDebuggerUrl);
  await cdp.ready();
  await cdp.send("Page.enable");
  await cdp.send("Runtime.enable");
  await cdp.send("Page.navigate", { url: "file://" + pageFile });
  // Wait for host object
  for (let i = 0; i < 50; i++) {
    const ev = await cdp.send("Runtime.evaluate", {
      expression: "typeof window.__R04_HOST__",
      returnByValue: true,
    });
    if (ev.result?.value === "object") break;
    await new Promise((r) => setTimeout(r, 50));
  }

  const bootEv = await cdp.send("Runtime.evaluate", {
    expression: "window.__R04_HOST__.boot()",
    awaitPromise: true,
    returnByValue: true,
  });
  state.cdp = cdp;
  return bootEv.result.value;
}

async function evalHost(expr) {
  const ev = await state.cdp.send("Runtime.evaluate", {
    expression: expr,
    awaitPromise: true,
    returnByValue: true,
  });
  if (ev.exceptionDetails) {
    throw new Error(JSON.stringify(ev.exceptionDetails));
  }
  return ev.result.value;
}

async function shutdown() {
  if (state.cdp) state.cdp.close();
  if (state.chrome) {
    state.chrome.kill("SIGKILL");
  }
  if (state.udd) {
    try {
      fs.rmSync(state.udd, { recursive: true, force: true });
    } catch {
      /* ignore */
    }
  }
  state = { chrome: null, udd: null, pageFile: null, cdp: null, port: null };
  return { ok: true };
}

const rl = createInterface({ input: process.stdin, crlfDelay: Infinity });
rl.on("line", async (line) => {
  let msg;
  try {
    msg = JSON.parse(line);
  } catch (e) {
    reply({ ok: false, error: "bad_json", detail: String(e) });
    return;
  }
  try {
    switch (msg.op) {
      case "boot":
        reply(await boot());
        break;
      case "sign": {
        const connId = JSON.stringify(String(msg.connId));
        const ch = JSON.stringify(String(msg.challengeB64));
        reply(
          await evalHost(`window.__R04_HOST__.sign(${connId}, ${ch})`)
        );
        break;
      }
      case "clear_ambient":
        reply(await evalHost("window.__R04_HOST__.clearAmbient()"));
        break;
      case "probe_export":
        reply(await evalHost("window.__R04_HOST__.probeExport()"));
        break;
      case "shutdown":
        reply(await shutdown());
        process.exit(0);
        break;
      default:
        reply({ ok: false, error: "unknown_op", op: msg.op });
    }
  } catch (e) {
    reply({ ok: false, error: String(e && e.message ? e.message : e) });
  }
});
