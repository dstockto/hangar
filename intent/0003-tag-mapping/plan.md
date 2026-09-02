# Plan: configurable tag mapping

1. `HangarCore/TagMapping.swift`, new. Candidates, lookup, normalize, and
   `isUngrouped` for the setup check.
2. `HangarConfig`: a `tags` field and `tagMapping` returning the configured
   mapping or the defaults, so a config predating the key still works.
3. `FleetStore`: normalize on fetch and on cache load.
4. `SSHConfigWriter`: stop appending the id alias when the stem already is the id.
5. `Preflight.taggingCheck`: use `isUngrouped`, and point at the config key.

## Tests

`TagMappingTests`, and they are the deliverable as much as the code is, because
the claim being made is "this works for fleets we have never seen":

- Environment/Service/Component with no configuration.
- Uppercase keys.
- app/stage/role.
- `Name` alone.
- Nothing at all.
- A custom mapping naming `BusinessUnit` and `DeployTier`.
- Original tags survive and remain filterable.
- Candidate order decides the winner.
- A canonical value does not linger when the mapping narrows.
