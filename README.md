# terraform-cato-bulk-lan-fw-rules

> [!IMPORTANT]
> This module targets the Cato Terraform provider `2.0.0` (general
> availability). Ensure your configuration resolves provider `2.0.0` or newer.


Bulk-manages the Cato **LAN Firewall (socketLan)** policy from a single JSON
export: sections (main and sub-policy owned), sub-policies, network rules, and
each network rule's nested child firewall rules, plus full ordering via
`cato_bulk_lf_move_rule`.

## Usage

### Basic Example

```hcl
module "lan_fw_rules" {
  source                      = "catonetworks/bulk-lan-fw-rules/cato"
  lan_fw_rules_json_file_path = "${path.module}/config_data/all_lan_fw_rules_and_sections.json"
}
```

### JSON Configuration Structure

Produced by:

```bash
catocli export lan_fw_rules --json-filename all_lan_fw_rules_and_sections.json
```

Root: `data.policy.socketLan.policy`. Entity references are exported as
`{name}`; refs whose names contain backslashes (e.g. network interfaces
`Site \ LAN 01`) arrive as `{id}` — the module passes either through.

#### Key Fields:

- `sections[]` — main sections and sub-policy-owned sub-sections (the latter
  carry a `sub_policy_name`).
- `sub_policies[]` — LAN Firewall sub-policies; see [Sub-policies](#sub-policies)
  for the scope/enabled-flag details.
- `network_rules[]` — top-level LAN FW rules, each carrying nested
  `firewall_rules[]` (the parent/child relationship is the nesting itself;
  array order is the per-parent order).
- `firewall_rules[]` — child rules nested under their parent `network_rules[]`
  entry.
- `rules_in_sections[]` — the ordering table; `entry_type: "sub_policy"` rows
  position scope rows. See [How Rule Ordering Works](#how-rule-ordering-works).

#### Resources Managed

| Resource | Keyed by | Notes |
|---|---|---|
| `cato_socket_lan_section.sections` | `section_name` | main sections |
| `cato_socket_lan_section.sub_sections` | `<sub_policy>::<section>` | created inside the sub-policy via `at.ref = sub-policy id` |
| `cato_lf_sub_policy.sub_policies` | `sub_policy_name` | scope body from `sub_policies[].scope`; `enabled` from `scope_enabled` |
| `cato_socket_lan_network_rule.network_rules` | rule name | placement: managed section → `LAST_IN_SECTION`; sub-policy w/o sub-section → `LAST_IN_POLICY` + `ref = sub-policy id`; sectionless → `LAST_IN_POLICY` |
| `cato_socket_lan_firewall_rule.firewall_rules` | `<network_rule>::<fw_rule>` | parent via `at = { position = "LAST_IN_RULE", ref = <network rule id> }` |
| `cato_bulk_lf_move_rule.all_lan_fw_rules` | — | orders sections, network rules (incl. sub-policy scope rows), and firewall children |

### How Rule Ordering Works

`rules_in_sections[]` — not array order in `sections[]`/`network_rules[]` —
determines actual ordering in the live policy. `entry_type: "sub_policy"` rows
position a sub-policy's scope row within that ordering, alongside normal
network-rule rows. A single `cato_bulk_lf_move_rule.all_lan_fw_rules` resource
reads that table and issues the moves for sections, network rules (including
sub-policy scope rows), and firewall children. Ordering rows with
`section_name: ""` (rules at the policy root, or inside a sub-policy without a
sub-section) are excluded from the move resource — they keep creation order,
and are surfaced for visibility via the `unordered_network_rules` output.

### Parameters

- `lan_fw_rules_json_file_path` (string, required) — path to the LAN Firewall
  (socketLan) JSON export produced by `catocli export lan_fw_rules`
  (`data.policy.socketLan.policy` root).
- `allow_empty_policy` (bool, default `false`) — safety guard: fails planning
  when the policy JSON contains 0 rules unless explicitly allowed. Protects
  against a truncated or wrong-tenant export destroying the live policy. Set
  `true` only for intentional greenfield/teardown.

## Working with Existing Rules (Brownfield Deployments)

### Installing and Configuring Cato CLI

1. **Install the Cato CLI:**
   ```bash
   pip3 install catocli
   ```

2. **Configure the CLI with your Cato credentials:**
   ```bash
   catocli configure set
   ```
   This will prompt you for your Cato Management Application credentials and account information.

### Exporting Existing Rules

Export the live LAN Firewall policy to JSON before adopting it into Terraform
state:

```bash
catocli export lan_fw_rules --json-filename all_lan_fw_rules_and_sections.json
```

### Importing Existing Rules into Terraform State (native import blocks)

Two ways to adopt existing state. All of this module's `for_each` state
addresses are keyed by name (`section_name`, `sub_policy_name`, network/
firewall rule name), which is exactly what lets both options below line up
directly against the exported JSON.

<details>
<summary>Option A (recommended) — native Terraform import blocks (migration.tf)</summary>

Requires Terraform >= 1.7. Create a one-shot `migration.tf` file beside your
module call with one `import` block per resource type:

<details>
<summary>migration.tf — import blocks for LAN Firewall</summary>

```hcl
locals {
  lanfw = jsondecode(file("./config_data/all_lan_fw_rules_and_sections.json")).data.policy.socketLan.policy

  lanfw_main_sections = {
    for s in local.lanfw.sections : s.section_name => s
    if try(s.sub_policy_name, null) == null
  }
  lanfw_sub_sections = {
    for s in local.lanfw.sections : "${s.sub_policy_name}::${s.section_name}" => s
    if try(s.sub_policy_name, null) != null
  }
  lanfw_sub_policies = {
    for sp in try(local.lanfw.sub_policies, []) : sp.sub_policy_name => sp
  }
  lanfw_network_rules = {
    for nr in local.lanfw.network_rules : nr.rule.name => nr.rule
  }
  lanfw_firewall_rules = merge([
    for nr in local.lanfw.network_rules : {
      for fw in try(nr.firewall_rules, []) :
      "${nr.rule.name}::${fw.rule.name}" => fw.rule
    }
  ]...)
}

import {
  for_each = local.lanfw_main_sections
  to       = module.lan_fw_rules.cato_socket_lan_section.sections[each.key]
  id       = each.value.section_id
}

import {
  for_each = local.lanfw_sub_sections
  to       = module.lan_fw_rules.cato_socket_lan_section.sub_sections[each.key]
  id       = each.value.section_id
}

import {
  for_each = local.lanfw_sub_policies
  to       = module.lan_fw_rules.cato_lf_sub_policy.sub_policies[each.key]
  id       = each.value.sub_policy_id
}

import {
  for_each = local.lanfw_network_rules
  to       = module.lan_fw_rules.cato_socket_lan_network_rule.network_rules[each.key]
  id       = each.value.id
}

import {
  for_each = local.lanfw_firewall_rules
  to       = module.lan_fw_rules.cato_socket_lan_firewall_rule.firewall_rules[each.key]
  id       = each.value.id
}

# cato_bulk_lf_move_rule.all_lan_fw_rules is plan-time ordering
# orchestration — it has no live object of its own, so it is never
# imported; it's created on the first apply after the resources above are
# adopted.
```

</details>

Terraform resolves the adoption order itself from each resource's own
`depends_on`/reference graph (the same graph main.tf already encodes):
sections → sub-policies → sub-sections → network rules → firewall rules.
You don't need to order the `import` blocks above by hand.

Preview before anything touches state:

```bash
terraform plan
```

Expect `N to import, 0 to add, 0 to change, 0 to destroy` (the `0 to add`
becoming `1 to add` only for `cato_bulk_lf_move_rule`, which is never
imported — see note above). Any non-zero "to change" means the JSON export
is stale relative to the live policy — **re-export**
(`catocli export lan_fw_rules`) and regenerate the locals above, rather than
letting `terraform apply` overwrite the live policy with stale config.

Once the plan looks right, adopt into state:

```bash
terraform apply
```

Then delete `migration.tf` — its job is done, and leaving it in place just
re-runs the same (no-op) import blocks on every future plan.

</details>

<details>
<summary>Option B — catocli import lan_fw_rules_to_tf (imperative alternative)</summary>

An imperative alternative to Option A, for when native import blocks aren't
practical (e.g. scripting a fully automated onboarding pipeline). Unlike
Option A, this mutates Terraform state immediately — there is no plan
preview before the import happens.

```bash
catocli import lan_fw_rules_to_tf config_data/all_lan_fw_rules_and_sections.json \
  --module-name module.lan_fw_rules --auto-approve
terraform plan   # expect: only cato_bulk_lf_move_rule.all_lan_fw_rules to add
```

Import order: sections → sub-policies → sub-sections → network rules →
firewall rules. The move resource is not importable; it is created on the
first apply.

</details>

### Typical Brownfield Workflow

1. Export the live policy: `catocli export lan_fw_rules --json-filename all_lan_fw_rules_and_sections.json`.
2. Write a one-shot `migration.tf` with the `import` blocks from Option A above.
3. `terraform plan` — expect only imports (`N to import, 0 to add, 0 to change, 0 to destroy`).
4. `terraform apply` to adopt the resources into state.
5. Delete `migration.tf` — its job is done.

### Backup and Restore Workflow

Re-export with `catocli export lan_fw_rules`, diff against the previous JSON
to see what changed on the live tenant, then `terraform plan` / `apply` to
reconcile. To restore to a last-known-good state, point
`lan_fw_rules_json_file_path` at a previously saved export and apply. Prefer
re-exporting over hand-editing — the JSON is a point-in-time tenant backup.

## Sub-policies

LAN Firewall sub-policies are exported under `sub_policies[]` and managed by
`cato_lf_sub_policy.sub_policies` (keyed by `sub_policy_name`). Each
sub-policy's own scope rule body comes from `sub_policies[].scope`.

Sub-policies can own sections of their own (`sections[]` entries carrying a
`sub_policy_name`), managed by `cato_socket_lan_section.sub_sections` (keyed
`<sub_policy>::<section>`) and created inside the sub-policy via
`at.ref = sub-policy id`. Network rules can belong to a sub-policy with or
without a sub-section — without one, placement falls back to
`LAST_IN_POLICY` with `ref = sub-policy id`. Scope rows for sub-policies are
also ordered via `rules_in_sections[]` entries with `entry_type: "sub_policy"`
(see [How Rule Ordering Works](#how-rule-ordering-works)).

There are two distinct "enabled" flags on a sub-policy, and they are not
interchangeable:

- `enabled` mirrors the sub-policy object's own `policy.enabled` — this is
  **not settable via the public API** (no enable input on `addSubPolicy`, no
  `updateSubPolicy`); it's informational only. Toggle it in CMA.
- `scope_enabled` is the scope rule's own flag, which this module *does*
  manage (surfaced via the `scope_rule_ids` output).

## Using Module Outputs

<details>
<summary>Example: referencing outputs from a calling root module</summary>

```hcl
output "lan_fw_summary" {
  value = module.lan_fw_rules.deployment_summary
}

# Look up a specific section's id for use elsewhere (e.g. a dashboard link)
output "trusted_section_id" {
  value = module.lan_fw_rules.section_ids["Trusted LAN"]
}

# Surface any rows that aren't covered by the move resource, so drift in
# creation-order rules doesn't go unnoticed
output "unordered_rules" {
  value = module.lan_fw_rules.unordered_network_rules
}
```

</details>

### Output Use Cases

- `deployment_summary` — quick counts of managed objects for dashboards or CI summaries.
- `section_ids` — map main section name → id, for cross-referencing sections elsewhere.
- `sub_policy_ids` — map sub-policy name → id, for referencing a sub-policy from other config.
- `sub_section_ids` — map `<sub_policy>::<section>` → id, for sub-policy-owned sections.
- `network_rule_ids` — map network rule name → id, for diagnostics or linking.
- `firewall_rule_ids` — map `<network_rule>::<firewall_rule>` → id, for child-rule lookups.
- `scope_rule_ids` — map sub-policy name → its scope rule id, to check `scope_enabled` state downstream.
- `unordered_network_rules` — rows excluded from `cato_bulk_lf_move_rule` (no managed section to order within); use to audit creation-order rules.

## Known limitations

- Run applies with `-parallelism=1` when several module instances share one
  account: reorders are account-wide and last-writer-wins.
- The CMA UI shows per-network-rule "Block Any" children and a "Default rules"
  section; these are UI-synthesized defaults the API does not return, so they
  never appear in exports and are not managed.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.5.0 |
| <a name="requirement_cato"></a> [cato](#requirement\_cato) | >= 2.0.0 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_cato"></a> [cato](#provider\_cato) | >= 2.0.0 |

## Modules

No modules.

## Resources

| Name | Type |
|------|------|
| [cato_bulk_lf_move_rule.all_lan_fw_rules](https://registry.terraform.io/providers/catonetworks/cato/latest/docs/resources/bulk_lf_move_rule) | resource |
| [cato_lf_sub_policy.sub_policies](https://registry.terraform.io/providers/catonetworks/cato/latest/docs/resources/lf_sub_policy) | resource |
| [cato_socket_lan_firewall_rule.firewall_rules](https://registry.terraform.io/providers/catonetworks/cato/latest/docs/resources/socket_lan_firewall_rule) | resource |
| [cato_socket_lan_network_rule.network_rules](https://registry.terraform.io/providers/catonetworks/cato/latest/docs/resources/socket_lan_network_rule) | resource |
| [cato_socket_lan_section.sections](https://registry.terraform.io/providers/catonetworks/cato/latest/docs/resources/socket_lan_section) | resource |
| [cato_socket_lan_section.sub_sections](https://registry.terraform.io/providers/catonetworks/cato/latest/docs/resources/socket_lan_section) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_allow_empty_policy"></a> [allow\_empty\_policy](#input\_allow\_empty\_policy) | Safety guard: fail planning when the policy JSON contains 0 rules unless explicitly allowed. Protects against a truncated or wrong-tenant export destroying the live policy. Set true only for intentional greenfield/teardown. | `bool` | `false` | no |
| <a name="input_lan_fw_rules_json_file_path"></a> [lan\_fw\_rules\_json\_file\_path](#input\_lan\_fw\_rules\_json\_file\_path) | Path to the LAN Firewall (socketLan) JSON export produced by `catocli export lan_fw_rules` (data.policy.socketLan.policy root). | `string` | n/a | yes |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_deployment_summary"></a> [deployment\_summary](#output\_deployment\_summary) | Counts of managed LAN firewall objects. |
| <a name="output_firewall_rule_ids"></a> [firewall\_rule\_ids](#output\_firewall\_rule\_ids) | Map of '<network\_rule>::<firewall\_rule>' to rule id. |
| <a name="output_network_rule_ids"></a> [network\_rule\_ids](#output\_network\_rule\_ids) | Map of network rule name to rule id. |
| <a name="output_scope_rule_ids"></a> [scope\_rule\_ids](#output\_scope\_rule\_ids) | Map of sub-policy name to its SUB\_POLICY\_SCOPE rule id. |
| <a name="output_section_ids"></a> [section\_ids](#output\_section\_ids) | Map of main section name to section id. |
| <a name="output_sub_policy_ids"></a> [sub\_policy\_ids](#output\_sub\_policy\_ids) | Map of sub-policy name to sub-policy id. |
| <a name="output_sub_section_ids"></a> [sub\_section\_ids](#output\_sub\_section\_ids) | Map of '<sub\_policy>::<section>' to section id. |
| <a name="output_unordered_network_rules"></a> [unordered\_network\_rules](#output\_unordered\_network\_rules) | rules\_in\_sections rows excluded from cato\_bulk\_lf\_move\_rule (no managed section to order within). |
<!-- END_TF_DOCS -->
