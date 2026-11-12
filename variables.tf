variable "lan_fw_rules_json_file_path" {
  description = "Path to the LAN Firewall (socketLan) JSON export produced by `catocli export lan_fw_rules` (data.policy.socketLan.policy root)."
  type        = string
}

variable "allow_empty_policy" {
  description = "Safety guard: fail planning when the policy JSON contains 0 rules unless explicitly allowed. Protects against a truncated or wrong-tenant export destroying the live policy. Set true only for intentional greenfield/teardown."
  type        = bool
  default     = false
}
