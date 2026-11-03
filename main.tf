# terraform-cato-bulk-lan-fw-rules
#
# Bulk-manages the Cato LAN Firewall (socketLan) policy from one JSON export
# produced by `catocli export lan_fw_rules`:
#   sections[]           main sections and sub-policy-owned sections (explicit
#                        sub_policy_name link)
#   sub_policies[]       one entry per sub-policy (scope row lifted out of the
#                        rule list; ids retained for brownfield import)
#   network_rules[]      network rules ({audit, rule, properties,
#                        sub_policy_name?, firewall_rules[]}); each child
#                        firewall rule nests inline — nesting IS the parent
#                        reference, array order is the per-parent order
#   rules_in_sections[]  THE ordering table for sections <-> network rules
#                        (entry_type "sub_policy" rows position scope rows)
#
# Supported shapes (all verified against live exports):
#   - sectionless policy (rules at policy root, section_name "")
#   - flat policy with sections
#   - sub-policies with and without their own sub-sections

locals {
  lanfw_json = jsondecode(file("${var.lan_fw_rules_json_file_path}"))
  lanfw      = local.lanfw_json.data.policy.socketLan.policy

  sections_data_raw      = try(local.lanfw.sections, [])
  sub_policies_data_raw  = try(local.lanfw.sub_policies, [])
  network_rules_data     = try(local.lanfw.network_rules, [])
  rules_in_sections_data = try(local.lanfw.rules_in_sections, [])

  # ─── sections: main vs sub-policy-owned ────────────────────────────────
  main_sections = {
    for s in local.sections_data_raw :
    s.section_name => s if try(s.sub_policy_name, null) == null
  }
  # Sub-sections are keyed "<sub_policy_name>::<section_name>" — two
  # sub-policies may each own a section with the same name.
  sub_sections = {
    for s in local.sections_data_raw :
    "${s.sub_policy_name}::${s.section_name}" => s
    if try(s.sub_policy_name, null) != null
  }
  # section_name -> composite key per sub-policy, for rule placement lookups.
  sub_section_key_by_name = {
    for k, s in local.sub_sections : "${s.sub_policy_name}::${s.section_name}" => k
  }

  sub_policies_data = {
    for sp in local.sub_policies_data_raw : sp.sub_policy_name => sp
  }

  # Parent section of each sub-policy, from its entry_type == "sub_policy"
  # ordering row (the scope row's position among sibling rules).
  sub_policy_parent_section = {
    for row in local.rules_in_sections_data :
    row.sub_policy_name => row.section_name
    if try(row.entry_type, "rule") == "sub_policy"
  }

  # ─── network rules ──────────────────────────────────────────────────────
  network_rules_by_name = {
    for nr in local.network_rules_data : nr.rule.name => nr
  }

  # Child firewall rules flattened to "<network_rule_name>::<fw_rule_name>",
  # carrying their 1-based position within the parent (array order).
  firewall_rules_flat = merge([
    for nr in local.network_rules_data : {
      for idx, fw in try(nr.firewall_rules, []) :
      "${nr.rule.name}::${fw.rule.name}" => {
        network_rule_name = nr.rule.name
        index_in_rule     = idx + 1
        entry             = fw
      }
    }
  ]...)

  # ─── move-resource inputs ───────────────────────────────────────────────
  # section_data: every managed section, main and sub, keyed as the section
  # resources are keyed.
  move_section_data = merge(
    {
      for name, s in local.main_sections : name => {
        section_index = s.section_index
      }
    },
    {
      for key, s in local.sub_sections : key => {
        section_index   = s.section_index
        section_name    = s.section_name
        sub_policy_name = s.sub_policy_name
      }
    }
  )

  # network_rules rows: plain rule rows plus sub-policy scope rows (keyed by
  # sub-policy name, mirroring the provider example which merges sub-policies
  # into the network_rules map). Rows whose section is not managed here
  # (section_name "" — sectionless policies or sub-policy rules without a
  # sub-section) are EXCLUDED and surfaced via the unordered_network_rules
  # output: the move resource addresses rules through sections.
  move_network_rules = merge(
    {
      for row in local.rules_in_sections_data :
      row.rule_name => {
        index_in_section = row.index_in_section
        section_name     = row.section_name
        section_key = try(row.sub_policy_name, null) != null ? try(
          local.sub_section_key_by_name["${row.sub_policy_name}::${row.section_name}"], null
        ) : null
      }
      if try(row.entry_type, "rule") == "rule" && row.section_name != "" && (
        try(row.sub_policy_name, null) == null ||
        contains(keys(local.sub_section_key_by_name), "${try(row.sub_policy_name, "")}::${row.section_name}")
      )
    },
    {
      for row in local.rules_in_sections_data :
      row.sub_policy_name => {
        index_in_section = row.index_in_section
        section_name     = row.section_name
      }
      if try(row.entry_type, "rule") == "sub_policy" && row.section_name != ""
    }
  )

  move_firewall_rules = {
    for key, fw in local.firewall_rules_flat : key => {
      firewall_rule_name = fw.entry.rule.name
      net_rule_name      = fw.network_rule_name
      index_in_rule      = fw.index_in_rule
    }
  }

  unordered_network_rules_data = [
    for row in local.rules_in_sections_data : row
    if try(row.entry_type, "rule") == "rule" && !contains(keys(local.move_network_rules), try(row.rule_name, ""))
  ]

  # ─── rule-body construction (API camelCase -> provider snake_case) ──────
  # Entity-ref lists arrive as [{name}] (ids stripped by the exporter) and are
  # passed through as name refs. Empty lists are omitted via try()-guards;
  # source/destination/site are always present (the provider expects the
  # blocks, empty objects are valid — matches the provider examples).

  network_rule_bodies = {
    for name, nr in local.network_rules_by_name : name => merge(
      {
        name      = nr.rule.name
        enabled   = try(nr.rule.enabled, true)
        direction = try(nr.rule.direction, "TO")
        transport = try(nr.rule.transport, "LAN")
        site = merge(
          try(length(nr.rule.site.site), 0) > 0 ? { site = [for x in nr.rule.site.site : can(x.name) ? { name = x.name } : { id = x.id }] } : {},
          try(length(nr.rule.site.group), 0) > 0 ? { group = [for x in nr.rule.site.group : can(x.name) ? { name = x.name } : { id = x.id }] } : {}
        )
        source      = local.lan_selector_bodies["net::${name}::source"]
        destination = local.lan_selector_bodies["net::${name}::destination"]
      },
      try(nr.rule.description, null) != null && try(nr.rule.description, "") != "" ? {
        description = nr.rule.description
      } : {},
      try(nr.rule.nat, null) != null ? {
        nat = {
          enabled  = try(nr.rule.nat.enabled, false)
          nat_type = try(nr.rule.nat.natType, null)
        }
      } : {},
      local.lan_service_bodies["net::${name}"]
    )
  }

  # Shared selector translation for network-rule-shaped source/destination
  # (also used for sub-policy scopes). Keyed "net::<rule>::<side>" /
  # "scope::<sub_policy>::<side>".
  lan_selector_sources = merge(
    { for name, nr in local.network_rules_by_name : "net::${name}::source" => try(nr.rule.source, {}) },
    { for name, nr in local.network_rules_by_name : "net::${name}::destination" => try(nr.rule.destination, {}) },
    { for name, sp in local.sub_policies_data : "scope::${name}::source" => try(sp.scope.source, {}) },
    { for name, sp in local.sub_policies_data : "scope::${name}::destination" => try(sp.scope.destination, {}) }
  )

  lan_selector_bodies = {
    for key, sel in local.lan_selector_sources : key => merge(
      try(length(sel.ip), 0) > 0 ? { ip = sel.ip } : {},
      try(length(sel.subnet), 0) > 0 ? { subnet = sel.subnet } : {},
      try(length(sel.vlan), 0) > 0 ? { vlan = sel.vlan } : {},
      try(length(sel.mac), 0) > 0 ? { mac = sel.mac } : {},
      try(length(sel.ipRange), 0) > 0 ? { ip_range = [for r in sel.ipRange : { from = r.from, to = r.to }] } : {},
      try(length(sel.host), 0) > 0 ? { host = [for x in sel.host : can(x.name) ? { name = x.name } : { id = x.id }] } : {},
      try(length(sel.site), 0) > 0 ? { site = [for x in sel.site : can(x.name) ? { name = x.name } : { id = x.id }] } : {},
      try(length(sel.group), 0) > 0 ? { group = [for x in sel.group : can(x.name) ? { name = x.name } : { id = x.id }] } : {},
      try(length(sel.systemGroup), 0) > 0 ? { system_group = [for x in sel.systemGroup : can(x.name) ? { name = x.name } : { id = x.id }] } : {},
      try(length(sel.globalIpRange), 0) > 0 ? { global_ip_range = [for x in sel.globalIpRange : can(x.name) ? { name = x.name } : { id = x.id }] } : {},
      try(length(sel.networkInterface), 0) > 0 ? { network_interface = [for x in sel.networkInterface : can(x.name) ? { name = x.name } : { id = x.id }] } : {},
      try(length(sel.siteNetworkSubnet), 0) > 0 ? { site_network_subnet = [for x in sel.siteNetworkSubnet : can(x.name) ? { name = x.name } : { id = x.id }] } : {},
      try(length(sel.floatingSubnet), 0) > 0 ? { floating_subnet = [for x in sel.floatingSubnet : can(x.name) ? { name = x.name } : { id = x.id }] } : {}
    )
  }

  # Service translation shared by network rules and sub-policy scopes.
  lan_service_sources = merge(
    { for name, nr in local.network_rules_by_name : "net::${name}" => try(nr.rule.service, null) },
    { for name, sp in local.sub_policies_data : "scope::${name}" => try(sp.scope.service, null) }
  )
  lan_service_bodies = {
    for key, svc in local.lan_service_sources : key => (
      svc == null ? {} : (
        try(length(svc.simple), 0) > 0 || try(length(svc.custom), 0) > 0 ? {
          service = merge(
            try(length(svc.simple), 0) > 0 ? { simple = [for x in svc.simple : can(x.name) ? { name = x.name } : { id = x.id }] } : {},
            try(length(svc.custom), 0) > 0 ? {
              custom = [for c in svc.custom : merge(
                { protocol = c.protocol },
                try(length(c.port), 0) > 0 ? { port = c.port } : {},
                try(c.portRange, null) != null ? { port_range = { from = c.portRange.from, to = c.portRange.to } } : {}
              )]
            } : {}
          )
        } : {}
      )
    )
  }

  firewall_rule_bodies = {
    for key, fw in local.firewall_rules_flat : key => merge(
      {
        name        = fw.entry.rule.name
        enabled     = try(fw.entry.rule.enabled, true)
        direction   = try(fw.entry.rule.direction, "TO")
        action      = try(fw.entry.rule.action, "ALLOW")
        source      = local.fw_selector_bodies["${key}::source"]
        destination = local.fw_selector_bodies["${key}::destination"]
        tracking = {
          event = { enabled = try(fw.entry.rule.tracking.event.enabled, false) }
          alert = merge(
            {
              enabled   = try(fw.entry.rule.tracking.alert.enabled, false)
              frequency = try(fw.entry.rule.tracking.alert.frequency, "HOURLY")
            },
            try(length(fw.entry.rule.tracking.alert.subscriptionGroup), 0) > 0 ? {
              subscription_group = [for x in fw.entry.rule.tracking.alert.subscriptionGroup : can(x.name) ? { name = x.name } : { id = x.id }]
            } : {},
            try(length(fw.entry.rule.tracking.alert.webhook), 0) > 0 ? {
              webhook = [for x in fw.entry.rule.tracking.alert.webhook : can(x.name) ? { name = x.name } : { id = x.id }]
            } : {},
            try(length(fw.entry.rule.tracking.alert.mailingList), 0) > 0 ? {
              mailing_list = [for x in fw.entry.rule.tracking.alert.mailingList : can(x.name) ? { name = x.name } : { id = x.id }]
            } : {}
          )
        }
      },
      try(fw.entry.rule.description, null) != null && try(fw.entry.rule.description, "") != "" ? {
        description = fw.entry.rule.description
      } : {},
      # application block: include only when any selector is present
      anytrue([
        try(length(fw.entry.rule.application.application), 0) > 0,
        try(length(fw.entry.rule.application.customApp), 0) > 0,
        try(length(fw.entry.rule.application.domain), 0) > 0,
        try(length(fw.entry.rule.application.fqdn), 0) > 0,
        try(length(fw.entry.rule.application.ip), 0) > 0,
        try(length(fw.entry.rule.application.subnet), 0) > 0,
        try(length(fw.entry.rule.application.ipRange), 0) > 0,
        try(length(fw.entry.rule.application.globalIpRange), 0) > 0,
        ]) ? {
        application = merge(
          try(length(fw.entry.rule.application.application), 0) > 0 ? { application = [for x in fw.entry.rule.application.application : can(x.name) ? { name = x.name } : { id = x.id }] } : {},
          try(length(fw.entry.rule.application.customApp), 0) > 0 ? { custom_app = [for x in fw.entry.rule.application.customApp : can(x.name) ? { name = x.name } : { id = x.id }] } : {},
          try(length(fw.entry.rule.application.domain), 0) > 0 ? { domain = fw.entry.rule.application.domain } : {},
          try(length(fw.entry.rule.application.fqdn), 0) > 0 ? { fqdn = fw.entry.rule.application.fqdn } : {},
          try(length(fw.entry.rule.application.ip), 0) > 0 ? { ip = fw.entry.rule.application.ip } : {},
          try(length(fw.entry.rule.application.subnet), 0) > 0 ? { subnet = fw.entry.rule.application.subnet } : {},
          try(length(fw.entry.rule.application.ipRange), 0) > 0 ? { ip_range = [for r in fw.entry.rule.application.ipRange : { from = r.from, to = r.to }] } : {},
          try(length(fw.entry.rule.application.globalIpRange), 0) > 0 ? { global_ip_range = [for x in fw.entry.rule.application.globalIpRange : can(x.name) ? { name = x.name } : { id = x.id }] } : {}
        )
      } : {},
      # firewall service additionally supports standard refs
      anytrue([
        try(length(fw.entry.rule.service.simple), 0) > 0,
        try(length(fw.entry.rule.service.standard), 0) > 0,
        try(length(fw.entry.rule.service.custom), 0) > 0,
        ]) ? {
        service = merge(
          try(length(fw.entry.rule.service.simple), 0) > 0 ? { simple = [for x in fw.entry.rule.service.simple : can(x.name) ? { name = x.name } : { id = x.id }] } : {},
          try(length(fw.entry.rule.service.standard), 0) > 0 ? { standard = [for x in fw.entry.rule.service.standard : can(x.name) ? { name = x.name } : { id = x.id }] } : {},
          try(length(fw.entry.rule.service.custom), 0) > 0 ? {
            custom = [for c in fw.entry.rule.service.custom : merge(
              { protocol = c.protocol },
              try(length(c.port), 0) > 0 ? { port = c.port } : {},
              try(c.portRange, null) != null ? { port_range = { from = c.portRange.from, to = c.portRange.to } } : {}
            )]
          } : {}
        )
      } : {}
    )
  }

  fw_selector_sources = merge(
    { for key, fw in local.firewall_rules_flat : "${key}::source" => try(fw.entry.rule.source, {}) },
    { for key, fw in local.firewall_rules_flat : "${key}::destination" => try(fw.entry.rule.destination, {}) }
  )
  fw_selector_bodies = {
    for key, sel in local.fw_selector_sources : key => merge(
      try(length(sel.ip), 0) > 0 ? { ip = sel.ip } : {},
      try(length(sel.subnet), 0) > 0 ? { subnet = sel.subnet } : {},
      try(length(sel.vlan), 0) > 0 ? { vlan = sel.vlan } : {},
      try(length(sel.mac), 0) > 0 ? { mac = sel.mac } : {},
      try(length(sel.ipRange), 0) > 0 ? { ip_range = [for r in sel.ipRange : { from = r.from, to = r.to }] } : {},
      try(length(sel.host), 0) > 0 ? { host = [for x in sel.host : can(x.name) ? { name = x.name } : { id = x.id }] } : {},
      try(length(sel.site), 0) > 0 ? { site = [for x in sel.site : can(x.name) ? { name = x.name } : { id = x.id }] } : {},
      try(length(sel.group), 0) > 0 ? { group = [for x in sel.group : can(x.name) ? { name = x.name } : { id = x.id }] } : {},
      try(length(sel.systemGroup), 0) > 0 ? { system_group = [for x in sel.systemGroup : can(x.name) ? { name = x.name } : { id = x.id }] } : {},
      try(length(sel.globalIpRange), 0) > 0 ? { global_ip_range = [for x in sel.globalIpRange : can(x.name) ? { name = x.name } : { id = x.id }] } : {},
      try(length(sel.networkInterface), 0) > 0 ? { network_interface = [for x in sel.networkInterface : can(x.name) ? { name = x.name } : { id = x.id }] } : {},
      try(length(sel.siteNetworkSubnet), 0) > 0 ? { site_network_subnet = [for x in sel.siteNetworkSubnet : can(x.name) ? { name = x.name } : { id = x.id }] } : {},
      try(length(sel.floatingSubnet), 0) > 0 ? { floating_subnet = [for x in sel.floatingSubnet : can(x.name) ? { name = x.name } : { id = x.id }] } : {}
    )
  }

  # Sub-policy scope bodies (network-rule-shaped; no transport attribute on the
  # provider's scope). enabled comes from scope_enabled — the scope rule's own
  # flag; sub_policies[].enabled mirrors the sub-policy object's policy.enabled,
  # which the public API cannot set (informational only, same as IFW).
  sub_policy_scope_bodies = {
    for name, sp in local.sub_policies_data : name => merge(
      {
        enabled   = try(sp.scope_enabled, true)
        direction = try(sp.scope.direction, "TO")
        site = merge(
          try(length(sp.scope.site.site), 0) > 0 ? { site = [for x in sp.scope.site.site : can(x.name) ? { name = x.name } : { id = x.id }] } : {},
          try(length(sp.scope.site.group), 0) > 0 ? { group = [for x in sp.scope.site.group : can(x.name) ? { name = x.name } : { id = x.id }] } : {}
        )
        source      = local.lan_selector_bodies["scope::${name}::source"]
        destination = local.lan_selector_bodies["scope::${name}::destination"]
      },
      try(sp.scope.nat, null) != null ? {
        nat = {
          enabled  = try(sp.scope.nat.enabled, false)
          nat_type = try(sp.scope.nat.natType, null)
        }
      } : {},
      local.lan_service_bodies["scope::${name}"]
    )
  }
}

# ───────────────────────────────────────────────────────────────────────────
# Sections: main sections at the policy root; sub-sections created inside
# their sub-policy by pointing at.ref at the sub-policy id (the provider's
# documented mechanism). Ordering is handled by cato_bulk_lf_move_rule.
# ───────────────────────────────────────────────────────────────────────────
resource "cato_socket_lan_section" "sections" {
  for_each = local.main_sections
  at = {
    position = "LAST_IN_POLICY"
  }
  section = {
    name = each.value.section_name
  }
}

resource "cato_lf_sub_policy" "sub_policies" {
  depends_on = [cato_socket_lan_section.sections]
  for_each   = local.sub_policies_data

  name        = each.value.sub_policy_name
  description = try(each.value.description, "")

  # Position the scope row inside its parent section when that section is
  # managed here; otherwise leave `at` unset (optional on this resource).
  at = contains(keys(local.main_sections), try(local.sub_policy_parent_section[each.key], "")) ? {
    position = "LAST_IN_SECTION"
    ref      = cato_socket_lan_section.sections[local.sub_policy_parent_section[each.key]].id
  } : null

  scope = local.sub_policy_scope_bodies[each.key]
}

resource "cato_socket_lan_section" "sub_sections" {
  for_each = local.sub_sections
  at = {
    position = "LAST_IN_POLICY"
    ref      = cato_lf_sub_policy.sub_policies[each.value.sub_policy_name].id
  }
  section = {
    name = each.value.section_name
  }
}

# ───────────────────────────────────────────────────────────────────────────
# Network rules. Placement:
#   main rule in a managed section      -> LAST_IN_SECTION ref=section id
#   main rule, sectionless policy       -> LAST_IN_POLICY (no ref)
#   sub-policy rule with a sub-section  -> LAST_IN_SECTION ref=sub-section id
#   sub-policy rule, no sub-section     -> LAST_IN_POLICY ref=sub-policy id
# ───────────────────────────────────────────────────────────────────────────
resource "cato_socket_lan_network_rule" "network_rules" {
  depends_on = [cato_socket_lan_section.sections, cato_socket_lan_section.sub_sections, cato_lf_sub_policy.sub_policies]
  for_each   = local.network_rules_by_name

  at = (
    try(each.value.sub_policy_name, null) != null ? (
      contains(keys(local.sub_sections), "${try(each.value.sub_policy_name, "")}::${each.value.rule.section.name}") ? {
        position = "LAST_IN_SECTION"
        ref      = cato_socket_lan_section.sub_sections["${each.value.sub_policy_name}::${each.value.rule.section.name}"].id
        } : {
        position = "LAST_IN_POLICY"
        ref      = cato_lf_sub_policy.sub_policies[each.value.sub_policy_name].id
      }
      ) : (
      contains(keys(local.main_sections), each.value.rule.section.name) ? {
        position = "LAST_IN_SECTION"
        ref      = cato_socket_lan_section.sections[each.value.rule.section.name].id
        } : {
        position = "LAST_IN_POLICY"
      }
    )
  )

  rule = local.network_rule_bodies[each.key]
}

resource "cato_socket_lan_firewall_rule" "firewall_rules" {
  depends_on = [cato_socket_lan_network_rule.network_rules]
  for_each   = local.firewall_rules_flat

  at = {
    position = "LAST_IN_RULE"
    ref      = cato_socket_lan_network_rule.network_rules[each.value.network_rule_name].rule.id
  }

  rule = local.firewall_rule_bodies[each.key]
}

# ───────────────────────────────────────────────────────────────────────────
# Ordering: sections, network rules (incl. sub-policy scope rows, merged in
# exactly like the provider example), and child firewall rules.
# ───────────────────────────────────────────────────────────────────────────
resource "cato_bulk_lf_move_rule" "all_lan_fw_rules" {
  depends_on = [
    cato_socket_lan_section.sections,
    cato_socket_lan_section.sub_sections,
    cato_lf_sub_policy.sub_policies,
    cato_socket_lan_network_rule.network_rules,
    cato_socket_lan_firewall_rule.firewall_rules,
  ]

  section_data   = local.move_section_data
  network_rules  = local.move_network_rules
  firewall_rules = local.move_firewall_rules
}
