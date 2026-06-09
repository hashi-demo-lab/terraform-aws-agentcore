output "agent_runtime_arn" {
  description = "ARN of the agent runtime."
  value       = module.agentcore.agent_runtime_arn
}

output "execution_role_arn" {
  description = "Runtime execution role ARN (created by the module)."
  value       = module.agentcore.execution_role_arn
}

output "kms_key_arn" {
  description = "Effective CMK ARN used for at-rest encryption."
  value       = module.agentcore.kms_key_arn
}
