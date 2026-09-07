# RHACS Credential Policies

Three policies detect credentials stored directly in container environment variables:

| Policy | Detects |
|---|---|
| Signature match | Recognizable credential formats, regardless of variable name |
| Vendor name and token shape | Vendor-specific token formats, documented password variables, and common passwords |
| Opaque value | Token-like values in variables whose names end with a credential term |

## Package structure

```text
detect-secrets/
├── kustomization.yaml
└── policies/
    ├── kustomization.yaml
    └── three SecurityPolicy YAML files
```

The synthetic credential examples are kept locally in `examples/` and excluded from Git because their token formats trigger GitHub push protection. They are not included in a fresh clone.

## Requirements

- OpenShift with RHACS installed.
- SecurityPolicy CRD and config-controller available.
- Access to apply policies in the `stackrox` namespace.

## Apply the policies

From `deploy/rhacs/policies/detect-secrets/`:

```sh
oc apply -k .
```

## Apply local examples

If you have the local examples directory:

```sh
oc apply -k examples/
```

This creates the `acs-policy-test` namespace and **349 example Deployments**. All examples use **zero replicas**, so no containers run.

## Expected results

Each Deployment includes:

- `acs-test/expect`: `fire` or `quiet`.
- `acs-test/sig`, `acs-test/vendor`, and `acs-test/heur`: expected matches.
- `acs-test/expected-policies` annotation: full names of the expected policies.

A `quiet` example should trigger none of these three custom policies. Other RHACS policies may still report violations.

Review the Deployments and their violations in RHACS, filtering by the `acs-policy-test` namespace.

## Validation

The policies passed manifest evaluation against CRC:

| Test set | Passed |
|---|---:|
| Main corpus | 325/325 |
| Additional boundary cases | 24/24 |

Boundary cases cover Secret and ConfigMap references, variable-name suffixes, token lengths, case sensitivity, and credentials split across variables or containers.

These results validate manifest matching. Runtime alert delivery and admission enforcement were not tested.

## Cleanup

Remove the example Deployments and their namespace:

```sh
oc delete -k examples/
```

The policies remain installed.
