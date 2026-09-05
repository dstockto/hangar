# 0027 plan: seven layers

One branch per layer, each opening a pull request on the one below it, so a
reviewer sees only that layer's diff. Later layers depend on earlier ones;
nothing depends on a layer above it.

`make test` and `evals/check.sh` are green at every layer, not only at the end.

## 1. `cli-command-model`

No behaviour change. Moves what is already there somewhere the suite can reach.

| File | Change |
|---|---|
| `HangarCore/HangarCommand.swift` | new: the parsed command line, and `parse` |
| `HangarCore/FleetOutput.swift` | new: the four formatters, returning strings |
| `hangar-cli/main.swift` | shrinks to: parse, load, select, print, exit |
| `Tests/HangarCommandTests.swift` | new |
| `Tests/FleetOutputTests.swift` | new |

Proves it: every flag the old parser accepted parses to the same thing, every
formatter produces the same bytes for the same entries, and the parse errors
keep their wording.

## 2. `cli-filter-expressions`

| File | Change |
|---|---|
| `HangarCore/HostFilter.swift` | new: `key=a,b`, `key!=a`, `\,`, wildcards |
| `HangarCore/FleetIndex.swift` | overload of `filtered` taking `[HostFilter]` |
| `HangarCommand.swift` | `-f` produces `[HostFilter]` |
| `Tests/HostFilterTests.swift` | new |
| `README.md` | the filter grammar |

Proves it: OR matches either and nothing else, `!=` excludes and keeps the rest,
an escaped comma matches a value containing one, two `-f` on one key AND, and
`FleetIndex.filtered(_:by:)` still answers a dictionary the old way for hotkeys.

## 3. `cli-json-fields`

| File | Change |
|---|---|
| `FleetOutput.swift` | new fields, `vcpus` as a number, `tags` nested, `[]` when empty |
| `hangar-cli/main.swift` | an empty match still prints JSON before exit 1 |
| `Tests/FleetOutputTests.swift` | the shape, and that empty is `[]` |
| `evals/product-json-is-always-valid.json` | new |
| `README.md` | the fields |

The eval runs the built binary against a fixture cache with a query that matches
nothing and pipes it through `python3 -m json.tool`. It fails today, which is
the admission criterion.

## 4. `cli-tag-discovery`

| File | Change |
|---|---|
| `HangarCore/TagCatalog.swift` | build a catalog from instances when the cache has none |
| `HangarCore/FleetOutput.swift` | catalog and value-count formatters |
| `HangarCommand.swift` | the `tags` and `values` verbs, `-s` and `--` escapes |
| `hangar-cli/main.swift` | dispatch |
| `Tests/TagCatalogTests.swift` | the recompute path |
| `Tests/HangarCommandTests.swift` | verbs, and both escapes |
| `README.md` | both commands |

## 5. `cli-human-output`

| File | Change |
|---|---|
| `HangarCore/FleetOutput.swift` | a terminal listing: headings, state, dimming |
| `HangarCore/Terminal.swift` | new: `isatty`, `NO_COLOR`, `TERM=dumb` |
| `hangar-cli/main.swift` | pick the listing by what stdout is |
| `Tests/FleetOutputTests.swift` | headings and state; colour off produces no escapes |
| `Tests/TerminalTests.swift` | new |

Proves it: with colour off the terminal listing contains no escape sequence, the
piped listing is byte for byte the old one, and a non-running host says its
state in words.

## 6. `cli-connect`

| File | Change |
|---|---|
| `HangarCore/SSHLogin.swift` | `SSHCommand.arguments`, the vector beside `line` |
| `HangarCore/FleetOutput.swift` | the numbered chooser |
| `HangarCommand.swift` | the `ssh` verb, `--first`, `--dry-run` |
| `hangar-cli/main.swift` | one match execs, several ask, none exits 1 |
| `Tests/SSHLoginTests.swift` | the vector matches the line, and `--` is present |
| `README.md` | the command, and exit code 3 |

`SSHCommand.line` is rewritten in terms of `arguments` so there is one answer to
"what does ssh get for this host", per mistake 18.

## 7. `cli-exec`

| File | Change |
|---|---|
| `HangarCore/ExecPlan.swift` | new: substitution, and the vector per host |
| `HangarCommand.swift` | `--exec` to end of line, `--parallel`, `--timeout`, `-y` |
| `hangar-cli/main.swift` | confirm, run, collect, exit 4 on any failure |
| `Tests/ExecPlanTests.swift` | new |
| `README.md` | `--exec`, the herdr example, the full exit table |
| `CLAUDE.md` | the architecture block gains the core files |

Proves it: a tag value containing `;` and `$(...)` reaches the child as one
argument unchanged, an unknown placeholder is left alone, `--parallel` never
exceeds its bound, and more than one host without `-y` and without a terminal is
a usage error rather than a fan-out.

## Not in any layer

`hangar refresh`, `hangar doctor`, an interactive picker, and shell completion.
The intent says why.
