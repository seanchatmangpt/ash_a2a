# How to: Using ash_a2a

## Prerequisites


- A2aDemo.Agent::handle_message (function)

- A2aDemo.Application::start (function)

- A2aDemo.Auth::issue_demo_grants (function)

- A2aDemo.Auth::verify (function)

- A2aDemo.Auth::verify (function)

- A2aDemo.CardSigning::jason_round_trip (function)

- A2aDemo.CardSigning::maybe_signatures (function)

- A2aDemo.CardSigning::verify_served (function)

- A2aDemo.GrpcHandler::call_opts (function)

- A2aDemo.GrpcHandler::get_task (function)

- A2aDemo.GrpcHandler::handle_cancel (function)

- A2aDemo.GrpcHandler::handle_get (function)

- A2aDemo.GrpcHandler::handle_list (function)

- A2aDemo.GrpcHandler::handle_send (function)

- A2aDemo.GrpcHandler::principal (function)

- A2aDemo.GrpcHandler::put_opt (function)

- A2aDemo.GrpcHandler::put_opt (function)

- A2aDemo.GrpcHandler::wire_error (function)

- A2aDemo.Note::A2aDemo.Note (ash_resource)

- A2aDemo.Router::call (function)

- A2aDemo.Router::call (function)

- A2aDemo.Router::call (function)

- A2aDemo.Router::call (function)

- A2aDemo.Router::init (function)

- A2aDemo.Router::mount (function)

- A2aDemo.Smoke::run (function)

- A2aDemo.Smoke::run_flows (function)

- Actuator.Anchor::check (function)

- Actuator.Anchor::path (function)

- Actuator.Anchor::prefix (function)

- Actuator.Anchor::prefix (function)

- Actuator.Anchor::read (function)

- Actuator.Anchor::sync_dir (function)

- Actuator.Anchor::write (function)

- Actuator.Application::server (function)

- Actuator.Application::start (function)

- Actuator.Application::tls (function)

- Actuator.Application::tls (function)

- Actuator.Application::uds (function)

- Actuator.Application::uds (function)


## Steps


1. Use `handle_message` from `A2aDemo.Agent`.

2. Use `start` from `A2aDemo.Application`.

3. Use `issue_demo_grants` from `A2aDemo.Auth`.

4. Use `verify` from `A2aDemo.Auth`.

5. Use `verify` from `A2aDemo.Auth`.

6. Use `jason_round_trip` from `A2aDemo.CardSigning`.

7. Use `maybe_signatures` from `A2aDemo.CardSigning`.

8. Use `verify_served` from `A2aDemo.CardSigning`.

9. Use `call_opts` from `A2aDemo.GrpcHandler`.

10. Use `get_task` from `A2aDemo.GrpcHandler`.

11. Use `handle_cancel` from `A2aDemo.GrpcHandler`.

12. Use `handle_get` from `A2aDemo.GrpcHandler`.


## Verified snippet

<!-- The snippet slot carries code copied from the extracted code surface -->
<!-- (doc:Claim rows whose doc:attribute is "snippet"), never agent prose. -->

```rust
// A2aDemo.Agent :: handle_message
handle_message/2
```

<!-- AGENT-COMMENTARY-BEGIN -->
<!-- The ONLY region an agent may write into. Bounds: <= 12 lines,    -->
<!-- <= 100 chars/line, no new code facts (any new symbol mentioned   -->
<!-- must exist in queries/ast_extract.rq output; the doc_quality     -->
<!-- court fails Phi_halluc > 0.001 otherwise). No tables, no         -->
<!-- signatures, no parameters, no error lists — AGENT-FORBIDDEN      -->
<!-- everywhere.                                                      -->
<!-- AGENT-COMMENTARY-END -->
