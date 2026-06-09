locals {
  # AgentCore runtime names must use underscores, not hyphens. Normalize the
  # consumer-supplied base name for the runtime (and runtime-scoped) resources.
  runtime_name = replace(var.name, "-", "_")

  # Module-default tags merged with consumer tags. Consumer tags win on key
  # collisions (merge applies later maps over earlier ones).
  module_tags = {
    Name      = var.name
    ManagedBy = "terraform"
  }
  tags = merge(local.module_tags, var.tags)

  # Effective customer-managed key ARN: the module-created key when
  # create_kms_key is true, otherwise the consumer-supplied ARN. Guarded with
  # try() so this stays valid before the KMS key resource lands in item B.
  kms_key_arn = var.create_kms_key ? try(aws_kms_key.this[0].arn, null) : var.kms_key_arn

  # Effective per-component execution role ARNs: the module-created role when
  # create_execution_role is true, otherwise the consumer-supplied ARN. Gateway
  # and memory roles are additionally gated on their feature toggle.
  runtime_execution_role_arn = var.create_execution_role ? try(aws_iam_role.runtime[0].arn, null) : var.runtime_execution_role_arn

  gateway_execution_role_arn = var.create_gateway ? (
    var.create_execution_role ? try(aws_iam_role.gateway[0].arn, null) : var.gateway_execution_role_arn
  ) : null

  memory_execution_role_arn = var.create_memory ? (
    var.create_execution_role ? try(aws_iam_role.memory[0].arn, null) : var.memory_execution_role_arn
  ) : null
}
