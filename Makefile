# Build the lean-lib CLI. Requires elan (provides lean/lake) on PATH.
.PHONY: build clean

build:
	LAKE_ARTIFACT_CACHE=true lake build

clean:
	lake clean
