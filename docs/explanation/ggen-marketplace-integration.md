# Semantic A2A Generation & Domain Extension Best Practices

This guide establishes the architectural boundaries and generation workflows for building domain capabilities on top of **`ash_a2a`** using **`ggen-marketplace`**.

---

## 1. Domain Agnosticism of the `ash_a2a` Core

`ash_a2a` is the generic protocol transport, supervision runtime, and consequence gateway for Semantic A2A:
- **What belongs in `ash_a2a/lib`**:
  - A2A protocol messaging and framing (`A2A.Message`, JSON-RPC, SSE).
  - Agent supervision and AgentCard compilation (`AshA2A.Agent`, `AshA2A.CapabilityIndex`).
  - Semantic Reasoning delegation via `AshGraphLaw` (`AshA2A.Semantic.HookReactor`).
  - Authority, Leases, and BRCE Consequence Fencing (`AshA2A.Authority`, `AshA2A.CommandBus`, `AshA2A.Receipt`).
  - Unified Identity (`AshA2A.Identity`).
- **What NEVER belongs in `ash_a2a/lib`**:
  - Vertical domain models (e.g., e-commerce, banking, loan origination, healthcare, manufacturing revops).
  - Domain-specific accounting tables, billing engines, or custom business rules.

---

## 2. Humans as First-Class Agents (`Human ⊑ Agent`)

In Semantic A2A, natural persons and automated bots share a unified identity schema. A human is not an out-of-band exception or conditional branch; a human is a first-class agent:

```elixir
# Both are valid AshA2A identities:
natural_person = AshA2A.Identity.agent("did:key:alice_human")
autonomous_bot = AshA2A.Identity.agent("did:key:procurement_agent_42")
```

### Regulatory Compliance (e.g. EU AI Act Article 14)
- When compliance mandates human oversight (such as transactions exceeding `$10,000 USD` or critical decisions):
  - The workflow is modeled as a cryptographic delegation DAG between agents.
  - The high-risk mandate requires co-signatures from both the initiating agent and a certified `NaturalPersonAgent`.
  - The runtime gate verifies the cryptographic lease without needing hardcoded "is_human" conditional branching in the core transport.

---

## 3. The 5-Stage GGen Generation Pipeline

To create domain capabilities for an Ash application:
1. **Model the Domain in RDF/OWL/SHACL**:
   - Create or extend a pack in `~/ggen-marketplace/packs/` (e.g. `sa2a-agent-economy-pack`).
2. **Define Formal Invariant Gates (SPARQL/SHACL)**:
   - Place validation queries in `gates/*.rq` to guarantee semantic constraints at compile-time.
3. **Write Code Generation Templates**:
   - Use Tera/EEx templates in `templates/` to project domain classes into Ash Resources, Ash Actions, and A2A Skills.
4. **Render Code via `ggen`**:
   - Run `ggen sync` to materialize verified, clean Elixir code into the target consumer project.
5. **Verify Receipts & Standing**:
   - Execute tests and generate Chatman receipts ($R$) binding exact subject SHAs.

---

## 4. Canonical Marketplace Packs Reference

| Pack Name | Purpose | Target Artifacts |
|:---|:---|:---|
| `sa2a-agent-economy-pack` | AP2 mandates, x402 micropayments, EU AI Act Art 12 & 14 governance | Economic resources & validation shapes |
| `elixir-mcp-a2a-pack` | Generates unified Elixir MCP router scopes and A2A AgentCard skills | `A2A.Agent` and `AshAi.Mcp.Router` code |
| `graphlaw-ash-capability-pack` | Projects typed GraphLaw ABI operations into Ash capabilities | `AshGraphLaw.Capability.*` modules |
| `chatman-marketplace-commerce-dod-pack` | Definition of Done for multi-marketplace commerce & billing authorities | Verification courts & compliance gates |
