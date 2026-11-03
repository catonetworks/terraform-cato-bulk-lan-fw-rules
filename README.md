# terraform-cato-bulk-lan-fw-rules

Bulk-manages the Cato **LAN Firewall (socketLan)** policy from a single JSON
export: sections (main and sub-policy owned), sub-policies, network rules, and
each network rule's nested child firewall rules, plus full ordering via
`cato_bulk_lf_move_rule`.

## Resources managed

| Resource | Keyed by | Notes |
|---|---|---|
| `cato_socket_lan_section.sections` | `section_name` | main sections |
| `cato_socket_lan_section.sub_sections` | `<sub_policy>::<section>` | created inside the sub-policy via `at.ref = sub-policy id` |
| `cato_lf_sub_policy.sub_policies` | `sub_policy_name` | scope body from `sub_policies[].scope`; `enabled` from `scope_enabled` |
| `cato_socket_lan_network_rule.network_rules` | rule name | placement: managed section → `LAST_IN_SECTION`; sub-policy w/o sub-section → `LAST_IN_POLICY` + `ref = sub-policy id`; sectionless → `LAST_IN_POLICY` |
| `cato_socket_lan_firewall_rule.firewall_rules` | `<network_rule>::<fw_rule>` | parent via `at = { position = "LAST_IN_RULE", ref = <network rule id> }` |
| `cato_bulk_lf_move_rule.all_lan_fw_rules` | — | orders sections, network rules (incl. sub-policy scope rows), and firewall children |

## Input JSON

Produced by:

```bash
catocli export lan_fw_rules --json-filename all_lan_fw_rules_and_sections.json
```

Root: `data.policy.socketLan.policy` with `sections[]`, `sub_policies[]`,
`network_rules[]` (each carrying nested `firewall_rules[]` — nesting is the
parent reference, array order is the per-parent order), and
`rules_in_sections[]` (the ordering table; `entry_type: "sub_policy"` rows
position scope rows). Entity references are exported as `{name}`; refs whose
names contain backslashes (e.g. network interfaces `Site \ LAN 01`) arrive as
`{id}` — the module passes either through.

Two enabled flags on sub-policies: `enabled` mirrors the sub-policy object's
own `policy.enabled` (not settable via the public API — informational), and
`scope_enabled` is the scope rule's flag, which this module manages.

## Usage

```hcl
module "lan_fw_rules" {
  source                      = "catonetworks/bulk-lan-fw-rules/cato"
  lan_fw_rules_json_file_path = "${path.module}/config_data/all_lan_fw_rules_and_sections.json"
}
```

## Brownfield import

```bash
catocli import lan_fw_rules_to_tf config_data/all_lan_fw_rules_and_sections.json \
  --module-name module.lan_fw_rules --auto-approve
terraform plan   # expect: only cato_bulk_lf_move_rule.all_lan_fw_rules to add
```

Import order: sections → sub-policies → sub-sections → network rules →
firewall rules. The move resource is not importable; it is created on the
first apply.

## Update workflow

Re-export with `catocli export lan_fw_rules`, diff against the previous JSON,
then `terraform plan` / `apply`. Prefer re-exporting over hand-editing — the
JSON is a point-in-time tenant backup.

## Known limitations

- Ordering rows with `section_name: ""` (rules at the policy root, or inside a
  sub-policy without a sub-section) are excluded from the move resource and
  surfaced via the `unordered_network_rules` output; their order is creation
  order.
- The sub-policy object's own `enabled` flag cannot be set via the public API
  (no enable input on `addSubPolicy`, no `updateSubPolicy`) — toggle it in CMA.
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
| <a name="requirement_cato"></a> [cato](#requirement\_cato) | >= 1.3.1 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_cato"></a> [cato](#provider\_cato) | >= 1.3.1 |

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