import Cli
import LeanLib

open Cli
open LeanLib

/-! CLI wiring: marshal `Cli.Parsed` into the handlers in `LeanLib.Commands`. -/

/-- Resolve the install root honoring a global `--root` flag on the parsed command. -/
private def rootOf (p : Parsed) : IO System.FilePath :=
  resolveRoot (p.flag? "root" |>.map (·.as! String))

/-- Split a comma-separated `--require a,b,c` into a trimmed, non-empty list. -/
private def parseRequires (p : Parsed) : List String :=
  match p.flag? "require" with
  | none => []
  | some f =>
    (f.as! String).splitOn "," |>.map trimStr |>.filter (!·.isEmpty)

def runInstall (p : Parsed) : IO UInt32 := do
  if (← verifyElan).isNone then return 127
  let name := p.positionalArg! "name" |>.as! String
  cmdInstall (← rootOf p) name
    (p.flag? "git" |>.map (·.as! String))
    (p.flag? "tag" |>.map (·.as! String))

def runList (p : Parsed) : IO UInt32 := do
  cmdList (← rootOf p)

def runNew (p : Parsed) : IO UInt32 := do
  if (← verifyElan).isNone then return 127
  let dir := p.positionalArg! "dir" |>.as! String
  cmdNew (← rootOf p) (System.FilePath.mk (← expandTilde dir)) (parseRequires p)
    (p.flag? "lib-name" |>.map (·.as! String))

def runManifest (p : Parsed) : IO UInt32 := do
  let lib := p.positionalArg! "lib" |>.as! String
  cmdManifest (← rootOf p) lib

def runUnlock (p : Parsed) : IO UInt32 := do
  let name := p.positionalArg! "name" |>.as! String
  cmdUnlock (← rootOf p) name

/-- Bare `lean-lib` with no subcommand: print help. -/
def runRoot (p : Parsed) : IO UInt32 := do
  p.printHelp
  return 0

def installCmd : Cmd := `[Cli|
  install VIA runInstall;
  "Clone and prepare a shared library under the install root (idempotent). \
   Mathlib uses the wiki cache-get flow; the build dir is locked read-only afterward."
  FLAGS:
    git : String; "Override the git clone URL (required for libraries not in the known list)."
    tag : String; "Check out this git tag/ref after cloning (recommended for reproducibility)."
    root : String; "Shared-library install root (overrides $LEAN_LIB_HOME/~/.lean/XDG default)."
  ARGS:
    name : String; "Short library name, e.g. mathlib, batteries, plausible."
]

def listCmd : Cmd := `[Cli|
  list VIA runList;
  "List shared libraries installed under the install root, with toolchain and git rev."
  FLAGS:
    root : String; "Shared-library install root (overrides $LEAN_LIB_HOME/~/.lean/XDG default)."
]

def newCmd : Cmd := `[Cli|
  new VIA runNew;
  "Scaffold a thin Lean project that path-requires shared libraries and build it \
   (no lake update, no re-download)."
  FLAGS:
    require : String;    "Comma-separated shared libs to require, e.g. --require batteries or \
                          --require mathlib,plausible. The first is primary (toolchain + manifest)."
    "lib-name" : String; "Library module name (default: derived from <dir>). Use this when the \
                          dir name would shadow a core namespace, e.g. --lib-name Latency."
    root : String;       "Shared-library install root (overrides $LEAN_LIB_HOME/~/.lean/XDG default)."
  ARGS:
    dir : String; "Target project directory (created if absent)."
]

def manifestCmd : Cmd := `[Cli|
  manifest VIA runManifest;
  "Regenerate lake-manifest.json in the current directory as path entries pointing at the \
   shared library (use after a shared-lib version bump)."
  FLAGS:
    root : String; "Shared-library install root (overrides $LEAN_LIB_HOME/~/.lean/XDG default)."
  ARGS:
    lib : String; "The shared library this project requires, e.g. mathlib or batteries."
]

def unlockCmd : Cmd := `[Cli|
  unlock VIA runUnlock;
  "Re-enable writes (chmod -R u+w) on a shared library's build dir, for upgrades."
  FLAGS:
    root : String; "Shared-library install root (overrides $LEAN_LIB_HOME/~/.lean/XDG default)."
  ARGS:
    name : String; "Short library name, e.g. mathlib."
]

-- The Cli DSL's `literalIdent` accepts a string literal in place of an identifier for the
-- command name. Using `"lean-lib"` here (rather than the guillemet-escaped identifier
-- `«lean-lib»`) avoids a Cli quirk where `Ident.getId.toString` echoes the guillemets
-- themselves into `--help` output.
def leanLibCmd : Cmd := `[Cli|
  "lean-lib" VIA runRoot; [version]
  "Deterministic scaffolder for Lean projects that reference shared, globally-installed \
   libraries (Mathlib, batteries, …) via path-requires. Assumes elan is installed."

  SUBCOMMANDS:
    installCmd;
    listCmd;
    newCmd;
    manifestCmd;
    unlockCmd
]

def main (args : List String) : IO UInt32 :=
  leanLibCmd.validate args
