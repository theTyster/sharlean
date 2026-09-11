import Lake
open Lake DSL

-- `sharlean`: a deterministic scaffolder for Lean projects that reference shared,
-- globally-installed libraries (Mathlib, batteries, …) via path-requires. Written in
-- Lean itself, depending on `leanprover/lean4-cli`. See README.md.

package sharlean where
  leanOptions := #[⟨`autoImplicit, false⟩]

require Cli from git "https://github.com/leanprover/lean4-cli" @ "v4.29.0"

@[default_target]
lean_lib Sharlean where

@[default_target]
lean_exe sharlean where
  root := `Main
