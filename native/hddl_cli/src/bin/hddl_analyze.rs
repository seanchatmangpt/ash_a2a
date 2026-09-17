//! Real, small, additive diagnostic binary: reuses the SAME real
//! `ferroplan_hddl` grounder/translator the solving path (`hddl_cli`'s
//! `main.rs`, via `ferroplan::solve_hddl`) already depends on -- no
//! reimplementation of parsing, grounding, or FOND solving -- and adds one
//! thing `hddl_cli` does not expose: exhaustive reachability + terminal-state
//! classification over the ground planning-problem graph `translate()`
//! already computes internally, whether or not the domain's own `:goal` is
//! ultimately strong-cyclically solvable.
//!
//! `hddl_cli` answers "is there a valid FOND policy?" (yes/no, via the real
//! solver). This binary answers a different, complementary real question:
//! "of every state the ground action/method graph can reach from :init, how
//! many are dead ends (no outgoing transition, i.e. no method/action applies
//! there), how many satisfy the stated :goal, and -- for each dead end --
//! which of the domain's own declared oneof-outcome predicates explains it?"
//! That second question is answerable by plain graph BFS over real,
//! already-ground data; it does not require (and does not attempt) any FOND
//! policy synthesis of its own.
//!
//! argv[1] = domain file, argv[2] = problem file, argv[3] (optional) =
//! comma-separated list of "marker" predicate name fragments (substring
//! match against each state's fact set) used to attribute terminal states to
//! a known, disclosed cause -- e.g. "unsupported,receipt-reconcile-blocked".
//! Prints one JSON object on stdout, exit 0 on success or 1 with an
//! `{"error": "..."}` object (same convention as `hddl_cli`).

use ferroplan_hddl::{grounder, parser, translate};
use serde::Serialize;
use std::collections::{BTreeMap, BTreeSet, HashSet, VecDeque};
use std::env;
use std::fs;

#[derive(Serialize)]
struct TerminalState {
    state_id: String,
    facts: Vec<String>,
    matched_markers: Vec<String>,
    explained: bool,
}

#[derive(Serialize)]
struct GoalState {
    state_id: String,
}

#[derive(Serialize)]
struct Report {
    total_ground_states: usize,
    total_transitions: usize,
    reachable_state_count: usize,
    terminal_state_count: usize,
    goal_satisfying_reachable_count: usize,
    goal_reachable: bool,
    explained_terminal_count: usize,
    unexplained_terminal_count: usize,
    unexplained_terminals: Vec<TerminalState>,
    explained_terminals: Vec<TerminalState>,
    goal_states: Vec<GoalState>,
}

fn err_out(msg: String) -> ! {
    println!("{}", serde_json::json!({ "error": msg }));
    std::process::exit(1);
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 3 {
        err_out("usage: hddl_analyze <domain.hddl> <problem.hddl> [comma,separated,markers]".into());
    }

    let domain_src = match fs::read_to_string(&args[1]) {
        Ok(s) => s,
        Err(e) => err_out(format!("reading domain file {}: {e}", args[1])),
    };
    let problem_src = match fs::read_to_string(&args[2]) {
        Ok(s) => s,
        Err(e) => err_out(format!("reading problem file {}: {e}", args[2])),
    };
    let markers: Vec<String> = args
        .get(3)
        .map(|s| s.split(',').map(|m| m.trim().to_string()).filter(|m| !m.is_empty()).collect())
        .unwrap_or_default();

    let domain = match parser::parse_domain(&domain_src) {
        Ok(d) => d,
        Err(e) => err_out(format!("parse domain: {e}")),
    };
    let problem = match parser::parse_problem(&problem_src) {
        Ok(p) => p,
        Err(e) => err_out(format!("parse problem: {e}")),
    };
    let ir = match grounder::ground(&domain, &problem, &Default::default()) {
        Ok(ir) => ir,
        Err(e) => err_out(format!("ground: {e}")),
    };
    let planning_problem = match translate::translate(&ir, &Default::default()) {
        Ok(p) => p,
        Err(e) => err_out(format!("translate: {e}")),
    };

    let states_by_id: BTreeMap<&str, &translate::State> = planning_problem
        .states
        .iter()
        .map(|s| (s.id.as_str(), s))
        .collect();

    // Real forward-reachability BFS over the real, already-ground transition
    // graph -- from `initial_states`, following every real `Transition`
    // (nondeterministic oneof outcomes are already flattened into distinct
    // Transition rows sharing the same `from`/`action`, so ordinary BFS over
    // `from -> to` edges visits every state any nondeterministic outcome
    // could actually land in; no solver-specific policy logic needed).
    let mut outgoing: BTreeMap<&str, Vec<&translate::Transition>> = BTreeMap::new();
    for t in &planning_problem.transitions {
        outgoing.entry(t.from.as_str()).or_default().push(t);
    }

    let mut reachable: HashSet<&str> = HashSet::new();
    let mut queue: VecDeque<&str> = VecDeque::new();
    for s in &planning_problem.initial_states {
        if reachable.insert(s.as_str()) {
            queue.push_back(s.as_str());
        }
    }
    while let Some(cur) = queue.pop_front() {
        if let Some(edges) = outgoing.get(cur) {
            for t in edges {
                if reachable.insert(t.to.as_str()) {
                    queue.push_back(t.to.as_str());
                }
            }
        }
    }

    let goal_facts = &planning_problem.goal.facts;
    let satisfies_goal = |facts: &BTreeSet<String>| goal_facts.is_subset(facts);

    let mut goal_states = Vec::new();
    let mut explained_terminals = Vec::new();
    let mut unexplained_terminals = Vec::new();

    for &id in &reachable {
        let Some(state) = states_by_id.get(id) else { continue };
        let has_outgoing = outgoing.get(id).map(|v| !v.is_empty()).unwrap_or(false);
        let is_goal = satisfies_goal(&state.facts);
        if is_goal {
            goal_states.push(GoalState { state_id: id.to_string() });
        }
        if !has_outgoing && !is_goal {
            // A goal-satisfying terminal is the real success case (nothing
            // left to decompose, htn:done), not a defect -- excluded above
            // via `!is_goal` and reported separately as `goal_states`.
            let facts: Vec<String> = state.facts.iter().cloned().collect();
            // Exact predicate-name match (the text before a fact's first
            // '(' -- e.g. "receipt-reconcile-blocked(command-episode-1)" ->
            // "receipt-reconcile-blocked"), NOT raw substring containment:
            // "blocked" is a real substring of both
            // "receipt-reconcile-blocked" and "candidate-blocked", which
            // would otherwise double-count those states under a spurious
            // "blocked" bucket alongside their real, distinct predicate.
            let predicate_names: Vec<&str> = facts
                .iter()
                .map(|f| f.split('(').next().unwrap_or(f.as_str()))
                .collect();
            let matched: Vec<String> = markers
                .iter()
                .filter(|m| predicate_names.iter().any(|p| *p == m.as_str()))
                .cloned()
                .collect();
            let entry = TerminalState {
                state_id: id.to_string(),
                facts,
                explained: !matched.is_empty(),
                matched_markers: matched,
            };
            if entry.explained {
                explained_terminals.push(entry);
            } else {
                unexplained_terminals.push(entry);
            }
        }
    }

    explained_terminals.sort_by(|a, b| a.state_id.cmp(&b.state_id));
    unexplained_terminals.sort_by(|a, b| a.state_id.cmp(&b.state_id));
    goal_states.sort_by(|a, b| a.state_id.cmp(&b.state_id));

    let report = Report {
        total_ground_states: planning_problem.states.len(),
        total_transitions: planning_problem.transitions.len(),
        reachable_state_count: reachable.len(),
        terminal_state_count: explained_terminals.len() + unexplained_terminals.len(),
        goal_satisfying_reachable_count: goal_states.len(),
        goal_reachable: !goal_states.is_empty(),
        explained_terminal_count: explained_terminals.len(),
        unexplained_terminal_count: unexplained_terminals.len(),
        unexplained_terminals,
        explained_terminals,
        goal_states,
    };

    match serde_json::to_string(&report) {
        Ok(json) => println!("{json}"),
        Err(e) => err_out(format!("serializing report: {e}")),
    }
}
