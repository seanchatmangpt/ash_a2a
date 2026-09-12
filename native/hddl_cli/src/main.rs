//! Real, small HDDL-solve CLI: argv[1] = domain file path, argv[2] = problem
//! file path. Calls the real `ferroplan::solve_hddl` (beam4pm's actual FOND
//! HTN solver, via a Cargo path-dependency -- not a reimplementation) and
//! prints the real `UniversalPlan` as JSON on stdout, exit 0. On any error
//! (missing files, HDDL parse/ground/translate/solve failure), prints
//! `{"error": "..."}` on stdout and exits 1.

use ferroplan::{solve_hddl, PlannerLimits};
use std::env;
use std::fs;
use std::process::ExitCode;

fn main() -> ExitCode {
    let args: Vec<String> = env::args().collect();
    if args.len() != 3 {
        println!(
            "{}",
            serde_json::json!({"error": "usage: hddl_cli <domain.hddl> <problem.hddl>"})
        );
        return ExitCode::FAILURE;
    }

    let domain_src = match fs::read_to_string(&args[1]) {
        Ok(s) => s,
        Err(e) => {
            println!(
                "{}",
                serde_json::json!({"error": format!("reading domain file {}: {e}", args[1])})
            );
            return ExitCode::FAILURE;
        }
    };
    let problem_src = match fs::read_to_string(&args[2]) {
        Ok(s) => s,
        Err(e) => {
            println!(
                "{}",
                serde_json::json!({"error": format!("reading problem file {}: {e}", args[2])})
            );
            return ExitCode::FAILURE;
        }
    };

    match solve_hddl(&domain_src, &problem_src, &PlannerLimits::default()) {
        Ok(plan) => match serde_json::to_string(&plan) {
            Ok(json) => {
                println!("{json}");
                ExitCode::SUCCESS
            }
            Err(e) => {
                println!("{}", serde_json::json!({"error": format!("serializing plan: {e}")}));
                ExitCode::FAILURE
            }
        },
        Err(e) => {
            println!("{}", serde_json::json!({"error": e.to_string()}));
            ExitCode::FAILURE
        }
    }
}
