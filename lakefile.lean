import Lake
open Lake DSL

-- `lean-lib`: a deterministic scaffolder for Lean projects that reference shared,
-- globally-installed libraries (Mathlib, batteries, …) via path-requires. Written in
-- Lean itself, depending on `leanprover/lean4-cli`. See README.md.

package leanLib where
  leanOptions := #[⟨`autoImplicit, false⟩]

require Cli from git "https://github.com/leanprover/lean4-cli" @ "v4.29.0"

@[default_target]
lean_lib LeanLib where

@[default_target]
lean_exe «lean-lib» where
  root := `Main
