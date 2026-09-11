/-!
# LeanLib.Util

Cross-cutting helpers: filesystem/env access, process orchestration, and resolution of the
shared-library install root. Kept dependency-light (core Lean + `Cli` only) so the CLI builds
in seconds against the shared `Cli` checkout.
-/

namespace LeanLib

/-- Trim ASCII whitespace, pinned to a `String` result. Single fix-point for the toolchain-dependent
    `String.trim` deprecation: if a future toolchain changes `.trim` to return `String.Slice`, only
    this definition needs updating (e.g. `s.trimAscii.toString`) rather than every call site. -/
def trimStr (s : String) : String := s.trimAscii.toString

/-- Expand a leading `~` to `$HOME`. Lake itself does not expand `~`, but the CLI accepts
    user-typed paths, so we normalize them before handing absolute paths to Lake. -/
def expandTilde (p : String) : IO String := do
  if p == "~" then
    return (← IO.getEnv "HOME").getD p
  else if "~/".isPrefixOf p then
    match ← IO.getEnv "HOME" with
    | some home => return home ++ p.drop 1
    | none => return p
  else
    return p

/-- The absolute path to the user's home directory, or `.` as a last resort. -/
def homeDir : IO System.FilePath := do
  return (← IO.getEnv "HOME").getD "." |> System.FilePath.mk

/--
Resolve the shared-library install root, in priority order:

1. an explicit `override` (the `--root` flag), if provided;
2. the `LEAN_LIB_HOME` environment variable;
3. an existing `~/.lean` directory (legacy / already-populated location);
4. `$XDG_DATA_HOME/lean` (default), falling back to `~/.local/share/lean`.

This lets an existing `~/.lean` clone keep working with zero migration while new setups land
in the XDG-correct location. A `~/.lean → $XDG_DATA_HOME/lean` symlink can bridge the two.
-/
def resolveRoot (override : Option String := none) : IO System.FilePath := do
  match override with
  | some r => return System.FilePath.mk (← expandTilde r)
  | none =>
    match ← IO.getEnv "LEAN_LIB_HOME" with
    | some r => return System.FilePath.mk (← expandTilde r)
    | none =>
      let home ← homeDir
      let legacy := home / ".lean"
      if ← legacy.pathExists then
        return legacy
      else
        match ← IO.getEnv "XDG_DATA_HOME" with
        | some xdg => return System.FilePath.mk xdg / "lean"
        | none => return home / ".local" / "share" / "lean"

/-- Run a command, streaming child stdout/stderr to ours; return the exit code. -/
def runCmd (cmd : String) (args : Array String) (cwd : Option System.FilePath := none)
    (env : Array (String × Option String) := #[]) : IO UInt32 := do
  let child ← IO.Process.spawn {
    cmd := cmd, args := args, cwd := cwd, env := env,
    stdout := .inherit, stderr := .inherit, stdin := .inherit }
  return (← child.wait)

/-- Run a command and capture stdout (trimmed). Returns `none` if the command exits nonzero
    or cannot be spawned. Used for probing (`elan --version`, `git rev-parse`, …). -/
def captureCmd (cmd : String) (args : Array String)
    (cwd : Option System.FilePath := none) : IO (Option String) := do
  try
    let out ← IO.Process.output { cmd := cmd, args := args, cwd := cwd }
    if out.exitCode == 0 then
      return some (trimStr out.stdout)
    else
      return none
  catch _ =>
    return none

/-- Verify `elan` is installed. On success returns its version line; on failure prints
    actionable guidance and returns `none`. The CLI assumes elan is present (it manages Lean
    toolchains) and never tries to install it. -/
def verifyElan : IO (Option String) := do
  match ← captureCmd "elan" #["--version"] with
  | some v => return some v
  | none =>
    IO.eprintln "error: `elan` not found on PATH."
    IO.eprintln "  lean-lib requires elan (the official Lean toolchain manager) to be installed."
    IO.eprintln "  Install it from https://github.com/leanprover/elan, then re-run."
    return none

/-- Ensure the toolchain named in `toolchainFile` is installed via elan (idempotent). -/
def ensureToolchain (toolchainFile : System.FilePath) : IO Unit := do
  if ← toolchainFile.pathExists then
    let tc := trimStr (← IO.FS.readFile toolchainFile)
    if !tc.isEmpty then
      -- `elan toolchain install` is a no-op if already present.
      let _ ← runCmd "elan" #["toolchain", "install", tc]
      pure ()

end LeanLib
