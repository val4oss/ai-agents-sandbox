---
name: Go modules investigation
description: Investigate Go module dependencies, vendor usage, and function references in a Go project.
when_to_use: When working with Go module dependencies — finding what modules are imported, checking if a vendored function is used, auditing go.mod/go.sum, or tracing dependency trees.
allowed-tools: Bash(go *), Bash(grep *), Bash(find *), Bash(cat *), Read
---

## Prerequisites

The project must have a `go.mod` file. All `go` commands should be run from the module root (where `go.mod` lives). Locate it first if not obvious:

```bash
find . -name "go.mod" -not -path "*/vendor/*" | head -5
```

## Listing direct and indirect dependencies

```bash
# All dependencies (direct + indirect) with versions
go list -m all

# Only direct dependencies (as declared in go.mod)
grep -E '^\s+[^/]' go.mod | grep -v '//'

# Pretty-print go.mod
cat go.mod
```

## Inspecting a specific module

```bash
# Show details of a module (version, path, dependencies)
go list -m -json <module-path>
# e.g.: go list -m -json github.com/pkg/errors

# Show why a module is required (who imports it)
go mod why <module-path>
# e.g.: go mod why golang.org/x/net
```

## Dependency graph

```bash
# Full dependency graph (module → its deps)
go mod graph

# Filter the graph to a specific module
go mod graph | grep <module-path>
```

## Finding which packages are actually imported

```bash
# All packages imported by the project (transitively)
go list -f '{{join .Imports "\n"}}' ./... | sort -u

# Only packages from a specific module
go list -f '{{join .Imports "\n"}}' ./... | grep <module-path> | sort -u

# Show import paths for a specific package
go list -json <package-path>
```

## Checking if a function from a vendor/module is used

**Search for direct call sites in source files:**

```bash
# Search all .go files for a function name (case-sensitive)
grep -rn "<FunctionName>" --include="*.go" .

# Restrict to a specific package path fragment
grep -rn "<FunctionName>" --include="*.go" . | grep "<package-or-path-fragment>"

# Include the surrounding context (3 lines)
grep -rn -A3 -B1 "<FunctionName>" --include="*.go" .
```

**Search for the import of a package:**

```bash
# Find all files that import a specific package
grep -rn '"<import-path>"' --include="*.go" .
# e.g.: grep -rn '"github.com/pkg/errors"' --include="*.go" .

# List unique files importing a package
grep -rln '"<import-path>"' --include="*.go" .
```

**Cross-reference: files that import the package AND call the function:**

```bash
PKG="github.com/example/pkg"
FN="MyFunction"
for f in $(grep -rln "\"$PKG\"" --include="*.go" .); do
  if grep -q "$FN" "$f"; then echo "$f"; fi
done
```

## Vendor directory

When a project vendors its dependencies (`vendor/` directory present):

```bash
# List vendored modules
cat vendor/modules.txt

# Check if a specific module is vendored
grep <module-path> vendor/modules.txt

# Search for a function inside the vendor tree
grep -rn "<FunctionName>" vendor/<module-path>/ --include="*.go"
```

## Tidying and auditing

```bash
# Verify go.sum is consistent with go.mod
go mod verify

# Simulate tidy (show what would change) — dry run
go mod tidy -diff   # requires Go 1.23+

# Tidy: remove unused, add missing dependencies
go mod tidy
```

## Upgrading or replacing a dependency

```bash
# Upgrade to latest
go get <module-path>@latest

# Pin to a specific version
go get <module-path>@v1.2.3

# Replace a module (e.g., local fork)
go mod edit -replace <module>=<replacement>
```

## Checking if the current version is in a vulnerable range

Once you know the affected version range from an advisory (e.g. `< v1.2.3`):

```bash
# Get the version currently used by the project
go list -m -json <module-path> | grep '"Version"'

# Check for replace directives that may override the version
grep -A2 'replace' go.mod | grep <module-path>
```

Go versions follow semver. Compare manually or use:

```bash
# One-liner: print version and let you eyeball against the range
go list -m all | grep <module-path>
```

Interpretation:
- If `Version` is **below** the fixed version → the project uses a vulnerable version.
- If `Version` is **at or above** the fixed version → already patched, stop investigation.
- If a `replace` directive points to a local path or different version, that version governs.

## Troubleshooting

- **`go: no module providing ...`** — run `go mod tidy` to resolve missing entries.
- **Version conflicts** — use `go mod graph | grep <module>` to trace who pulls in each version; use `go get <module>@<version>` to pin.
- **Vendor out of sync** — run `go mod vendor` to regenerate, then `go mod verify`.
- **Build uses wrong version** — check for `replace` directives in `go.mod` with `grep replace go.mod`.
