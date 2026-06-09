output "agent_runtime_arn" {
  description = "ARN of the agent runtime."
  value       = module.agentcore.agent_runtime_arn
}

output "gateway_url" {
  description = "Gateway MCP URL."
  value       = module.agentcore.gateway_url
}

output "memory_id" {
  description = "AgentCore Memory ID."
  value       = module.agentcore.memory_id
}

output "token_vault_cmk_key_arn" {
  description = "CMK ARN applied to the Identity token vault."
  value       = module.agentcore.token_vault_cmk_key_arn
}

output "api_key_credential_provider_arns" {
  description = "Map of name to API-key credential provider ARN."
  value       = module.agentcore.api_key_credential_provider_arns
}

output "oauth2_credential_provider_arns" {
  description = "Map of name to OAuth2 credential provider ARN."
  value       = module.agentcore.oauth2_credential_provider_arns
}
