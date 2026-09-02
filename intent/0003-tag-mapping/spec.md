# Spec: configurable tag mapping

## Shape

`TagMapping` holds a list of candidate keys per concept: `product`, `env`,
`env_name`, `role`, `hostname`. Candidates are tried in order, matched exactly
first and then case-insensitively, and the first non-empty value wins.

Defaults cover the conventions in use:

| Concept | Candidates |
|---|---|
| product | product, Product, service, Service, app, App, Application, project, Project, system, System |
| env | env, Env, environment, Environment, stage, Stage, tier, Tier |
| env_name | env_name, envName, EnvName, environment_name, instance_name, cluster, Cluster |
| role | Name, name, role, Role, component, Component, function, Function, purpose, Purpose |
| hostname | hostname, Hostname, HostName, host, Host, fqdn, FQDN, dns, DNS, dns_name, DNSName |

## Normalization

`normalize(_:)` rewrites an instance's tags so the canonical keys carry the
resolved values, and the original keys are kept. Everything downstream keeps
reading `product` and `env` and needs no idea the fleet spells them differently.
A canonical key that resolves to nothing is removed, so re-normalizing a cached
instance under a narrower mapping clears the stale value.

Normalization happens where instances enter: on fetch, and on cache load, so a
mapping change applies without waiting for a refresh.

## Degradation

- One `Name` tag alone gives a usable alias, which is the single most common case.
- A wholly untagged instance still gets a working alias from its instance id, and
  no longer gets the id pinned to itself as a second alias.
- The setup check names the config key to edit instead of only reporting that the
  fleet is untagged.

## Acceptance

Given `Service=payments, Environment=prod, Component=web` and no configuration,
the alias is `payments-prod-web`.
