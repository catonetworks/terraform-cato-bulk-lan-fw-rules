output "deployment_summary" {
  description = "Counts of managed LAN firewall objects."
  value = {
    sections       = length(cato_socket_lan_section.sections)
    sub_sections   = length(cato_socket_lan_section.sub_sections)
    sub_policies   = length(cato_lf_sub_policy.sub_policies)
    network_rules  = length(cato_socket_lan_network_rule.network_rules)
    firewall_rules = length(cato_socket_lan_firewall_rule.firewall_rules)
  }
}

output "section_ids" {
  description = "Map of main section name to section id."
  value       = { for name, s in cato_socket_lan_section.sections : name => s.id }
}

output "sub_section_ids" {
  description = "Map of '<sub_policy>::<section>' to section id."
  value       = { for key, s in cato_socket_lan_section.sub_sections : key => s.id }
}

output "sub_policy_ids" {
  description = "Map of sub-policy name to sub-policy id."
  value       = { for name, sp in cato_lf_sub_policy.sub_policies : name => sp.id }
}

output "scope_rule_ids" {
  description = "Map of sub-policy name to its SUB_POLICY_SCOPE rule id."
  value       = { for name, sp in cato_lf_sub_policy.sub_policies : name => sp.scope_rule_id }
}

output "network_rule_ids" {
  description = "Map of network rule name to rule id."
  value       = { for name, r in cato_socket_lan_network_rule.network_rules : name => r.rule.id }
}

output "firewall_rule_ids" {
  description = "Map of '<network_rule>::<firewall_rule>' to rule id."
  value       = { for key, r in cato_socket_lan_firewall_rule.firewall_rules : key => r.rule.id }
}

# Ordering rows the move resource cannot address (section_name "" — rules at
# the policy root, or inside a sub-policy without a sub-section). Their order
# is creation order. Informational only.
output "unordered_network_rules" {
  description = "rules_in_sections rows excluded from cato_bulk_lf_move_rule (no managed section to order within)."
  value       = local.unordered_network_rules_data
}
