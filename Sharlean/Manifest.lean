import Lean.Data.Json
import Sharlean.Util

/-!
# Sharlean.Manifest

A project that consumes a shared library must NOT run `lake update` (it re-clones every
transitive dependency from GitHub). Instead we synthesize a `lake-manifest.json` whose entries
are all `type: "path"`, pointing at the shared clone's already-checked-out packages. This is the
sanctioned "globally-shared mathlib installation" pattern.

`generate` reads the *shared library's own* manifest (which lists its transitive deps as git
entries) and rewrites each as a path entry under `<sharedLibDir>/.lake/packages/<name>`, prepending
the shared library itself as the first path entry.
-/

open Lean

namespace Sharlean.Manifest

/-- One resolved dependency as a `type:"path"` manifest entry. -/
structure PathEntry where
  name : String
  dir : String
  inherited : Bool := false
  scope : String := ""
  configFile : String := "lakefile.toml"
  deriving Inhabited

def PathEntry.toJson (e : PathEntry) : Json :=
  Json.mkObj [
    ("type", "path"),
    ("name", e.name),
    ("dir", e.dir),
    ("inherited", e.inherited),
    ("scope", e.scope),
    ("configFile", e.configFile),
    ("manifestFile", "lake-manifest.json")]

/-- Read a string field from a JSON object, defaulting when absent/ill-typed. -/
private def strField (j : Json) (key : String) (dflt : String) : String :=
  (j.getObjValAs? String key).toOption.getD dflt

private def boolField (j : Json) (key : String) (dflt : Bool) : Bool :=
  (j.getObjValAs? Bool key).toOption.getD dflt

/--
Build the ordered list of path entries for a project requiring the shared library at
`sharedLibDir` (an absolute path, e.g. `~/.lean/mathlib4`). The `libName` is how the project
`require`s it (e.g. `"mathlib"`, `"batteries"`).

The shared library is entry #1; each transitive dep from its manifest that actually exists under
`.lake/packages/<name>` is appended. Missing packages are reported to stderr and skipped.
-/
def buildEntries (sharedLibDir : System.FilePath) (libName : String)
    (libConfigFile : String) : IO (Array PathEntry) := do
  let manifestPath := sharedLibDir / "lake-manifest.json"
  unless ← manifestPath.pathExists do
    throw <| IO.userError s!"shared library manifest not found: {manifestPath}\n  \
      Run `lake exe cache get` (or `sharlean install`) in the shared clone first."
  let raw ← IO.FS.readFile manifestPath
  let json ← IO.ofExcept (Json.parse raw)
  let pkgsDir := sharedLibDir / ".lake" / "packages"

  -- Entry #1: the shared library itself.
  let mut entries : Array PathEntry := #[{
    name := libName, dir := sharedLibDir.toString,
    inherited := false, scope := "", configFile := libConfigFile }]

  -- Each transitive dependency, rewritten to a local path.
  let pkgs := (json.getObjVal? "packages").toOption.getD (Json.arr #[])
  let pkgArr := pkgs.getArr?.toOption.getD #[]
  for pkg in pkgArr do
    let name := strField pkg "name" ""
    if name.isEmpty then continue
    let pkgPath := pkgsDir / name
    if ← pkgPath.pathExists then
      entries := entries.push {
        name := name, dir := pkgPath.toString,
        inherited := boolField pkg "inherited" false,
        scope := strField pkg "scope" "",
        configFile := strField pkg "configFile" "lakefile.toml" }
    else
      IO.eprintln s!"warning: {name} not found at {pkgPath}, skipping"
  return entries

/-- Serialize a full project manifest JSON from the given path entries. -/
def renderManifest (projectName : String) (entries : Array PathEntry) : Json :=
  Json.mkObj [
    ("version", "1.1.0"),
    ("packagesDir", ".lake/packages"),
    ("packages", Json.arr (entries.map PathEntry.toJson)),
    ("name", projectName),
    ("lakeDir", ".lake")]

/--
Generate `<projectDir>/lake-manifest.json` for `projectName`, resolving all deps of the shared
library at `sharedLibDir` to path entries. Returns the number of dependency entries written
(excluding the shared library itself).
-/
def generate (projectDir : System.FilePath) (projectName : String)
    (sharedLibDir : System.FilePath) (libName : String)
    (libConfigFile : String := "lakefile.lean") : IO Nat := do
  let entries ← buildEntries sharedLibDir libName libConfigFile
  let out := renderManifest projectName entries
  IO.FS.writeFile (projectDir / "lake-manifest.json") (out.pretty ++ "\n")
  return entries.size - 1

end Sharlean.Manifest
