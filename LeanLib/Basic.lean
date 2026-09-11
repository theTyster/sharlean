/-!
# LeanLib.Basic

Placeholder module so `lean_lib LeanLib` has a root to compile. Real logic lives in
sibling modules added as the CLI grows (`LeanLib.Manifest`, `LeanLib.Root`, …).
-/

namespace LeanLib

/-- Tool version string, surfaced by `lean-lib --version`. -/
def version : String := "0.1.0"

end LeanLib
