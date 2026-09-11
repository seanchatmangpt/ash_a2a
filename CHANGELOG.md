# Changelog

All notable changes to `ash_a2a` are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project intends to adhere to [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
once it reaches 1.0.

## [26.9.10] - 2026-09-10

### Added
- Spark DSL for defining A2A (Agent-to-Agent) agents, actions, and skills.
- Capability index (`AshA2A.CapabilityIndex`) with `Validator` and `AgentCardBuilder`
  decomposed as separate modules.
- Dispatcher for routing A2A requests to Ash actions/skills.
- Task history/context threading through to dispatch instead of being discarded.
- Installer for wiring `ash_a2a` into a host application.

### Fixed
- `AgentCard` `supported_interfaces` proto-drift.
- Dispatcher `KeyError` on skill lookup.
- `__spark_metadata__` verification issues.

## [Unreleased]

Nothing yet.
