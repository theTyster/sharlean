import Sharlean.Util
import Sharlean.Manifest

/-!
# Sharlean.Commands

The subcommand implementations. Each takes the already-resolved arguments and returns a Unix
exit code. The `Cli`-facing handlers live in `Main.lean` and just marshal `Parsed` into these.
-/

namespace Sharlean

/-- Known shared libraries: canonical git URL keyed by short name. Extend as needed. -/
def knownRepos : List (String × String) :=
  [ ("mathlib",   "https://github.com/leanprover-community/mathlib4.git"),
    ("batteries", "https://github.com/leanprover-community/batteries.git"),
    ("plausible", "https://github.com/leanprover-community/plausible.git") ]

def repoUrlFor (name : String) : Option String :=
  (knownRepos.find? (·.1 == name)).map (·.2)

/-- A shared library's on-disk directory: some libs (mathlib) clone into a differently-named
    directory (`mathlib4`) than the `require` name (`mathlib`). Normalize here. -/
def libDirName (name : String) : String :=
  if name == "mathlib" then "mathlib4" else name

/-- Read the git short-rev and toolchain of an installed shared lib, for `list`. -/
private def libInfo (dir : System.FilePath) : IO (String × String) := do
  let rev := (← captureCmd "git" #["rev-parse", "--short", "HEAD"] dir).getD "?"
  let tc ← do
    let tcFile := dir / "lean-toolchain"
    if ← tcFile.pathExists then pure (trimStr (← IO.FS.readFile tcFile)) else pure "?"
  return (rev, tc)

/-- `sharlean list` — enumerate installed shared libraries under the root. -/
def cmdList (root : System.FilePath) : IO UInt32 := do
  unless ← root.pathExists do
    IO.println s!"No shared-library root at {root} (nothing installed yet)."
    return 0
  IO.println s!"Shared Lean libraries in {root}:"
  let mut found := false
  for entry in (← root.readDir) do
    let dir := entry.path
    -- A lib dir is one containing a lakefile.
    let hasLake := (← (dir / "lakefile.toml").pathExists) || (← (dir / "lakefile.lean").pathExists)
    if (← dir.isDir) && hasLake then
      found := true
      let (rev, tc) ← libInfo dir
      IO.println s!"  • {entry.fileName}  [{tc}]  @ {rev}"
  unless found do IO.println "  (none)"
  return 0

/--
`sharlean install <name>` — clone (if absent) and prepare a shared library.

For mathlib, follows the wiki shared-install flow (cache get). For any lib, builds it and then
`chmod -R a-w` the `.lake/build` to guard against Lake occasionally deleting the shared clone.

Idempotency is keyed on **build artifacts**, not on the directory existing: a fully-built lib
(`.lake/build` present) is left untouched; a cloned-but-unbuilt lib (e.g. a previous run that
failed after clone) resumes at the toolchain+build step. This makes a partial install recoverable
by re-running, and prevents reporting `✔ ready` for a lib that never built.
-/
def cmdInstall (root : System.FilePath) (name : String)
    (gitOverride : Option String) (tag : Option String) : IO UInt32 := do
  IO.FS.createDirAll root
  let dir := root / libDirName name
  let buildDir := dir / ".lake" / "build"

  -- Fast path: already fully built. Only ensure the lock is applied.
  if ← buildDir.pathExists then
    IO.println s!"{name} already built at {dir}."
    IO.println s!"Ensuring {buildDir} is locked read-only (chmod -R a-w)."
    let _ ← runCmd "chmod" #["-R", "a-w", buildDir.toString]
    IO.println s!"✔ {name} ready at {dir}"
    return 0

  -- Clone if the source is not present yet.
  if ← dir.pathExists then
    IO.println s!"{name} cloned but not built at {dir}; resuming build."
  else
    let url ← match gitOverride <|> repoUrlFor name with
      | some u => pure u
      | none => do
        IO.eprintln s!"error: unknown library '{name}' and no --git URL given."
        IO.eprintln s!"  known: {String.intercalate ", " (knownRepos.map (·.1))}"
        return 1
    IO.println s!"Cloning {name} from {url} → {dir} …"
    let rc ← runCmd "git" #["clone", url, dir.toString]
    if rc != 0 then return rc
    match tag with
    | some t =>
      IO.println s!"Checking out {t} …"
      let rc ← runCmd "git" #["-C", dir.toString, "checkout", t]
      if rc != 0 then return rc
    | none =>
      IO.println "No --tag given; leaving at default branch HEAD. \
        Consider pinning a stable tag for reproducibility."

  -- Toolchain + build (runs on both first-install and resume-after-partial paths).
  ensureToolchain (dir / "lean-toolchain")
  if name == "mathlib" then
    IO.println "Fetching prebuilt oleans (lake exe cache get) …"
    let rc ← runCmd "lake" #["exe", "cache", "get"] (cwd := dir)
    if rc != 0 then return rc
  else
    IO.println "Building shared library …"
    let rc ← runCmd "lake" #["build"] (cwd := dir)
      (env := #[("LAKE_ARTIFACT_CACHE", some "true")])
    if rc != 0 then return rc

  -- Only lock (and claim success) if the build actually produced artifacts.
  unless ← buildDir.pathExists do
    IO.eprintln s!"error: {name} did not produce {buildDir}; install incomplete."
    return 1
  IO.println s!"Locking {buildDir} read-only (chmod -R a-w) to prevent accidental deletion."
  let _ ← runCmd "chmod" #["-R", "a-w", buildDir.toString]
  IO.println s!"✔ {name} ready at {dir}"
  return 0

/-- `sharlean unlock <name>` — re-enable writes on a shared lib's build dir (for upgrades). -/
def cmdUnlock (root : System.FilePath) (name : String) : IO UInt32 := do
  let buildDir := root / libDirName name / ".lake" / "build"
  unless ← buildDir.pathExists do
    IO.eprintln s!"error: {buildDir} does not exist."
    return 1
  IO.println s!"Unlocking {buildDir} (chmod -R u+w) for upgrade."
  return (← runCmd "chmod" #["-R", "u+w", buildDir.toString])

/-- Resolve a required lib name to its shared-clone directory, erroring if not installed. -/
private def requireLibDir (root : System.FilePath) (name : String) :
    IO (Option System.FilePath) := do
  let dir := root / libDirName name
  if ← dir.pathExists then
    return some dir
  else
    IO.eprintln s!"error: required library '{name}' not installed at {dir}."
    IO.eprintln s!"  Install it first:  sharlean install {name}"
    return none

/-- Choose the lakefile config-file name a shared lib uses (for manifest entries). -/
private def libConfigFile (dir : System.FilePath) : IO String := do
  if ← (dir / "lakefile.lean").pathExists then return "lakefile.lean" else return "lakefile.toml"

/--
`sharlean new <projectDir> --require <lib>` — scaffold a thin project that path-requires a single
shared lib. Writes `lakefile.toml`, copies `lean-toolchain` from the lib, generates the
path-manifest, and builds.

Only ONE `--require` is accepted for now. A correct multi-require would need to union every lib's
transitive closure (with a consistent first-wins dedup so the generated manifest paths agree with
the `[[require]]` paths); until that lands, multiple requires are rejected rather than silently
mis-resolved (a secondary lib would either be missing from the manifest or shadowed by the
primary's pinned copy).
-/
def cmdNew (root : System.FilePath) (projectDir : System.FilePath)
    (requires : List String) (libNameOverride : Option String := none) : IO UInt32 := do
  if requires.isEmpty then
    IO.eprintln "error: `new` needs a --require <lib> (e.g. --require batteries)."
    return 1
  if requires.length > 1 then
    let joined := String.intercalate ", " requires
    IO.eprintln s!"error: multiple --require libs are not supported yet ({joined})."
    IO.eprintln "  Scaffold with the primary lib, then add extra requires to lakefile.toml and \
      run `sharlean manifest <primary>` (a real multi-lib union is a TODO)."
    return 1
  -- Resolve the (single) required lib up front.
  let mut libDirs : List (String × System.FilePath) := []
  for name in requires do
    match ← requireLibDir root name with
    | some d => libDirs := libDirs ++ [(name, d)]
    | none => return 1
  let projName := (dropTrailingSep projectDir).fileName.getD "Proofs"
  -- Library module name: explicit --lib-name, else derived from the dir. Sanitized to a valid
  -- capitalized identifier and rejected if it would shadow a core namespace (e.g. `lean`→`Lean`).
  let rawName := libNameOverride.getD projName
  let libModule := sanitizeModule rawName
  if isReservedModule libModule then
    IO.eprintln s!"error: library module name '{libModule}' shadows a core Lean namespace."
    IO.eprintln "  Pass --lib-name <Name> to choose a different module name \
      (e.g. --lib-name Latency)."
    return 1
  IO.FS.createDirAll projectDir
  IO.FS.createDirAll (projectDir / libModule)

  -- lakefile.toml with absolute path-requires.
  let requireLines := String.intercalate "\n" (← libDirs.mapM fun (nm, d) => do
    pure s!"\n[[require]]\nname = \"{nm}\"\npath = \"{d}\"")
  let lakefile :=
    s!"name = \"{projName}\"\n\
       defaultTargets = [\"{libModule}\"]\n\n\
       [leanOptions]\n\
       autoImplicit = false\n\n\
       [[lean_lib]]\n\
       name = \"{libModule}\"\n\
       {requireLines}\n"
  IO.FS.writeFile (projectDir / "lakefile.toml") lakefile

  -- Root module + a placeholder so the lib compiles.
  IO.FS.writeFile (projectDir / s!"{libModule}.lean")
    s!"-- Root module for {projName}. Add files under {libModule}/ and import them here.\n"
  IO.FS.writeFile (projectDir / libModule / "Basic.lean")
    s!"-- {projName}: first module. Replace with real content.\n"

  -- Toolchain from the required lib — must match its prebuilt oleans.
  let (libNm, libDir) := libDirs.head!
  let srcTc := libDir / "lean-toolchain"
  if ← srcTc.pathExists then
    IO.FS.writeFile (projectDir / "lean-toolchain") (← IO.FS.readFile srcTc)

  -- Path manifest: the required lib plus its transitive deps, all as `type:path` entries pointing
  -- at the shared clone (single-require is enforced above, so this is the complete closure).
  let cfg ← libConfigFile libDir
  let depCount ← Manifest.generate projectDir projName libDir libNm cfg
  IO.println s!"Generated lake-manifest.json ({depCount} deps from {libNm})."

  -- Build with the shared artifact cache; no network fetch, no recompile of the shared lib.
  IO.println "Building project (LAKE_ARTIFACT_CACHE=true lake build) …"
  let rc ← runCmd "lake" #["build"] (cwd := projectDir)
    (env := #[("LAKE_ARTIFACT_CACHE", some "true")])
  if rc != 0 then
    IO.eprintln "Build failed. Check that the toolchain matches the shared lib and that the \
      lib is installed."
    return rc
  IO.println s!"✔ Project ready at {projectDir}"
  return 0
where
  /-- Drop trailing path separators so `foo/` yields `fileName = foo`, not `none`. -/
  dropTrailingSep (p : System.FilePath) : System.FilePath :=
    System.FilePath.mk ((p.toString.dropEndWhile (· == '/')).toString)
  /-- Turn an arbitrary dir name into a valid capitalized Lean module identifier: keep alphanumerics,
      capitalize the first letter, and prefix `M` if it would otherwise start with a digit (Lean
      module names cannot begin with a digit). -/
  sanitizeModule (s : String) : String :=
    let chars := s.toList.filter Char.isAlphanum
    match chars with
    | [] => "Proofs"
    | c :: rest =>
      if c.isDigit then String.ofList ('M' :: c :: rest)
      else String.ofList (c.toUpper :: rest)
  /-- Module names that would shadow a core Lean/toolchain namespace or a known shared library's
      root module, breaking imports. -/
  isReservedModule (s : String) : Bool :=
    ["Lean", "Init", "Std", "Lake", "Cli",
     "Mathlib", "Batteries", "Plausible", "Aesop", "Qq"].contains s

/-- Best-effort read of the top-level package `name = "..."` from a `lakefile.toml`. Returns `none`
    if the file or key is absent. Only used to keep a regenerated manifest's `name` consistent with
    the lakefile (Lake matches them). Operates on plain `String` throughout (no `.trim`, whose return
    type is toolchain-dependent) by splitting on the quote characters. -/
private def readTomlPackageName (lakefile : System.FilePath) : IO (Option String) := do
  unless ← lakefile.pathExists do return none
  let content ← IO.FS.readFile lakefile
  for line in content.splitOn "\n" do
    -- Match a `name = "value"` assignment. The first top-level `name =` in a lakefile.toml is the
    -- package name; we strip spaces and tabs before the prefix check.
    let noSpace := (line.replace " " "").replace "\t" ""
    if noSpace.startsWith "name=\"" then
      match line.splitOn "\"" with
      | _ :: v :: _ => return some v
      | _ => pure ()
  return none

/--
`sharlean manifest <libName>` — (re)generate `lake-manifest.json` in the CURRENT directory for
an existing project that requires the shared lib `libName`. Use after a shared-lib version bump.

Requires a `lakefile.toml`/`lakefile.lean` in the CWD (so it cannot be run in a non-project dir),
and takes the manifest `name` from the lakefile's `name =` when available (falling back to the dir
name) so the regenerated manifest stays consistent with the package.
-/
def cmdManifest (root : System.FilePath) (libName : String) : IO UInt32 := do
  let cwd ← IO.currentDir
  let hasToml ← (cwd / "lakefile.toml").pathExists
  let hasLean ← (cwd / "lakefile.lean").pathExists
  unless hasToml || hasLean do
    IO.eprintln s!"error: no lakefile.toml/lakefile.lean in {cwd}."
    IO.eprintln "  Run `sharlean manifest` from inside a Lean project directory."
    return 1
  -- Guard: the project must actually `require` this lib, else we would overwrite its manifest with
  -- an unrelated dependency (a real footgun — e.g. running `manifest batteries` in a Cli-based
  -- project). Match a genuine require, not a mention in a comment: either a `require <lib>` line
  -- (lakefile.lean) or a `name = "<lib>"` line (lakefile.toml `[[require]]` block).
  let lakePath := if hasToml then cwd / "lakefile.toml" else cwd / "lakefile.lean"
  let lakeContent ← IO.FS.readFile lakePath
  let requiresLib := (lakeContent.splitOn "\n").any fun line =>
    let ns := (line.replace " " "").replace "\t" ""
    (ns.startsWith "require" && (line.splitOn libName).length > 1)
      || ns.startsWith s!"name=\"{libName}\""
  unless requiresLib do
    IO.eprintln s!"error: {lakePath.fileName.getD "lakefile"} does not `require` '{libName}'."
    IO.eprintln s!"  `manifest` regenerates for a lib the project already requires; add a \
      `require {libName}` first, or run it in the right project."
    return 1
  match ← requireLibDir root libName with
  | none => return 1
  | some dir =>
    let projName := (← readTomlPackageName (cwd / "lakefile.toml")).getD (cwd.fileName.getD "Proofs")
    let cfg ← libConfigFile dir
    let depCount ← Manifest.generate cwd projName dir libName cfg
    IO.println s!"Wrote {cwd / "lake-manifest.json"} ({depCount} deps from {libName}, name=\"{projName}\")."
    return 0

end Sharlean
