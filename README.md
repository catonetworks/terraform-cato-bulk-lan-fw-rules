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
