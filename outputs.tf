###############################################################################
# Runtime (always-on)
###############################################################################

output "agent_runtime_arn" {
  description = "ARN of the agent runtime."
  value       = try(aws_bedrockagentcore_agent_runtime.this.agent_runtime_arn, null)
}

output "agent_runtime_id" {
  description = "ID of the agent runtime."
  value       = try(aws_bedrockagentcore_agent_runtime.this.agent_runtime_id, null)
}

output "agent_runtime_version" {
  description = "Current version of the agent runtime."
  value       = try(aws_bedrockagentcore_agent_runtime.this.agent_runtime_version, null)
}

output "agent_runtime_endpoint_arn" {
  description = "ARN of the runtime endpoint; null when not created."
  value       = try(aws_bedrockagentcore_agent_runtime_endpoint.this[0].agent_runtime_endpoint_arn, null)
}

output "workload_identity_arn" {
  description = "Implicit workload identity ARN emitted by the runtime."
  value       = try(aws_bedrockagentcore_agent_runtime.this.workload_identity_details[0].workload_identity_arn, null)
}

###############################################################################
# Encryption & IAM
###############################################################################

output "execution_role_arn" {
  description = "Runtime execution role ARN (created or supplied)."
  value       = local.runtime_execution_role_arn
}

output "kms_key_arn" {
  description = "Effective CMK ARN used for encryption (created or supplied); null if neither."
  value       = local.kms_key_arn
}

###############################################################################
# Gateway
###############################################################################

output "gateway_arn" {
  description = "Gateway ARN; null when disabled."
  value       = try(aws_bedrockagentcore_gateway.this[0].gateway_arn, null)
}

output "gateway_id" {
  description = "Gateway ID; null when disabled."
  value       = try(aws_bedrockagentcore_gateway.this[0].gateway_id, null)
}

output "gateway_url" {
  description = "Gateway MCP/HTTP URL; null when disabled."
  value       = try(aws_bedrockagentcore_gateway.this[0].gateway_url, null)
}

output "gateway_target_ids" {
  description = "Map of target name to target ID; empty when disabled."
  value       = try({ for k, v in aws_bedrockagentcore_gateway_target.this : k => v.id }, {})
}

###############################################################################
# Memory
###############################################################################

output "memory_arn" {
  description = "Memory ARN; null when disabled."
  value       = try(aws_bedrockagentcore_memory.this[0].arn, null)
}

output "memory_id" {
  description = "Memory ID; null when disabled."
  value       = try(aws_bedrockagentcore_memory.this[0].id, null)
}

output "memory_strategy_ids" {
  description = "Map of strategy name to strategy ID; empty when disabled."
  value       = try({ for k, v in aws_bedrockagentcore_memory_strategy.this : k => v.id }, {})
}

###############################################################################
# Identity
###############################################################################

output "token_vault_cmk_key_arn" {
  description = "CMK ARN applied to the Identity token vault; null when disabled."
  value       = try(aws_bedrockagentcore_token_vault_cmk.this[0].kms_configuration[0].kms_key_arn, null)
}

output "api_key_credential_provider_arns" {
  description = "Map of name to API-key credential provider ARN."
  value       = try({ for k, v in aws_bedrockagentcore_api_key_credential_provider.this : k => v.credential_provider_arn }, {})
}

output "api_key_secret_arns" {
  description = "Map of name to Secrets Manager secret ARN for API-key providers."
  value       = try({ for k, v in aws_bedrockagentcore_api_key_credential_provider.this : k => v.api_key_secret_arn }, {})
  sensitive   = true
}

output "oauth2_credential_provider_arns" {
  description = "Map of name to OAuth2 credential provider ARN."
  value       = try({ for k, v in aws_bedrockagentcore_oauth2_credential_provider.this : k => v.credential_provider_arn }, {})
}

output "oauth2_client_secret_arns" {
  description = "Map of name to Secrets Manager client-secret ARN."
  value       = try({ for k, v in aws_bedrockagentcore_oauth2_credential_provider.this : k => v.client_secret_arn }, {})
  sensitive   = true
}

output "standalone_workload_identity_arn" {
  description = "Standalone workload identity ARN; null when disabled."
  value       = try(aws_bedrockagentcore_workload_identity.this[0].workload_identity_arn, null)
}
