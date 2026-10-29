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
`.lake/packages/<name>` (or, for a path entry, at its `dir`) is appended. Missing packages are
reported to stderr and skipped.
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
    -- A lib whose own deps were linked to shared clones (`linkShared`) lists them as path entries;
    -- follow those dirs instead of looking under its `.lake/packages`.
    let pkgPath : System.FilePath :=
      if strField pkg "type" "git" == "path" then
        let d := System.FilePath.mk (strField pkg "dir" "")
        if d.isAbsolute then d else sharedLibDir / d
      else pkgsDir / name
    if ← pkgPath.pathExists then
      entries := entries.push {
        name := name, dir := pkgPath.toString,
        inherited := boolField pkg "inherited" false,
        scope := strField pkg "scope" "",
        configFile := strField pkg "configFile" "lakefile.toml" }
    else
      IO.eprintln s!"warning: {name} not found at {pkgPath}, skipping"
  return entries

/-- The `packages` array of a manifest file. -/
private def readPackages (manifestPath : System.FilePath) : IO (Json × Array Json) := do
  let json ← IO.ofExcept (Json.parse (← IO.FS.readFile manifestPath))
  let pkgs := (json.getObjVal? "packages").toOption.getD (Json.arr #[])
  return (json, pkgs.getArr?.toOption.getD #[])

/-- A library's direct (non-inherited) git dependencies as `(name, rev, inputRev)`, read from its
    own `lake-manifest.json`. Empty when the lib has no manifest. -/
def directGitDeps (libDir : System.FilePath) : IO (Array (String × String × String)) := do
  let manifestPath := libDir / "lake-manifest.json"
  unless ← manifestPath.pathExists do return #[]
  let (_, pkgs) ← readPackages manifestPath
  return pkgs.filterMap fun pkg =>
    let name := strField pkg "name" ""
    if name.isEmpty || strField pkg "type" "" != "git" || boolField pkg "inherited" false then none
    else some (name, strField pkg "rev" "", strField pkg "inputRev" "")

/-- Whether a lib's own manifest has any path entries, i.e. it was linked onto shared clones
    (`linkShared`) and so builds against their locked `.lake/build` dirs. -/
def hasPathDeps (libDir : System.FilePath) : IO Bool := do
  let manifestPath := libDir / "lake-manifest.json"
  unless ← manifestPath.pathExists do return false
  let (_, pkgs) ← readPackages manifestPath
  return pkgs.any (strField · "type" "" == "path")

/--
Rewrite `<libDir>/lake-manifest.json` so each dependency in `shared` (name, shared clone dir,
config file) is a path entry at that clone, followed by the clone's own transitive deps (from its
manifest, via `buildEntries`). Entries the shared closures already provide are dropped (first wins);
every other entry is kept unchanged. The lib's `lakefile.toml` must path-require the same dirs.
-/
def linkShared (libDir : System.FilePath)
    (shared : Array (String × System.FilePath × String)) : IO Unit := do
  let manifestPath := libDir / "lake-manifest.json"
  let (json, pkgs) ← readPackages manifestPath
  let mut out : Array Json := #[]
  let mut seen : Array String := #[]
  for (name, dir, cfg) in shared do
    for e in ← buildEntries dir name cfg do
      unless seen.contains e.name do
        seen := seen.push e.name
        out := out.push { e with inherited := e.name != name }.toJson
  for pkg in pkgs do
    let name := strField pkg "name" ""
    unless seen.contains name do
      seen := seen.push name
      out := out.push pkg
  let updated := json.setObjVal! "packages" (Json.arr out)
  IO.FS.writeFile manifestPath (updated.pretty ++ "\n")

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
