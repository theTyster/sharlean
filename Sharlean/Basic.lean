/-!
# Sharlean.Basic

Placeholder module so `lean_lib Sharlean` has a root to compile. Real logic lives in
sibling modules added as the CLI grows (`Sharlean.Manifest`, `Sharlean.Root`, …).
-/

namespace Sharlean

/-- Tool version string, surfaced by `sharlean --version`. -/
def version : String := "0.1.0"

end Sharlean
