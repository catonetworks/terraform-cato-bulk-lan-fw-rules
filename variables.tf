variable "lan_fw_rules_json_file_path" {
  description = "Path to the LAN Firewall (socketLan) JSON export produced by `catocli export lan_fw_rules` (data.policy.socketLan.policy root)."
  type        = string
}
