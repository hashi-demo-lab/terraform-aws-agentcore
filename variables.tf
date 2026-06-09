###############################################################################
# Core / Runtime
###############################################################################

variable "name" {
  type        = string
  description = "Base name used as a prefix for all resources. Runtime names auto-convert hyphens to underscores."

  validation {
    condition     = length(var.name) >= 1 && length(var.name) <= 32
    error_message = "name must be between 1 and 32 characters."
  }

  validation {
    condition     = can(regex("^[a-zA-Z][a-zA-Z0-9_-]*$", var.name))
    error_message = "name must start with a letter and contain only letters, digits, underscores, and hyphens."
  }
}

variable "container_uri" {
  type        = string
  description = "Consumer-provided ECR container image URI (<acct>.dkr.ecr.<region>.amazonaws.com/<repo>:<tag>) for the runtime."

  validation {
    condition     = length(var.container_uri) > 0
    error_message = "container_uri must be non-empty."
  }

  validation {
    condition     = can(regex("\\.dkr\\.ecr\\..*amazonaws\\.com/", var.container_uri))
    error_message = "container_uri must be a valid ECR image URI (<acct>.dkr.ecr.<region>.amazonaws.com/<repo>:<tag>)."
  }
}

variable "network_mode" {
  type        = string
  default     = "PUBLIC"
  description = "Runtime network mode. Only PUBLIC supported this iteration; reserved for future VPC."

  validation {
    condition     = contains(["PUBLIC"], var.network_mode)
    error_message = "network_mode only supports PUBLIC this iteration."
  }
}

variable "server_protocol" {
  type        = string
  default     = "MCP"
  description = "Runtime inbound application protocol."

  validation {
    condition     = contains(["HTTP", "MCP", "A2A"], var.server_protocol)
    error_message = "server_protocol must be one of HTTP, MCP, A2A."
  }
}

variable "environment_variables" {
  type        = map(string)
  default     = {}
  description = "Environment variables injected into the runtime container."
}

variable "description" {
  type        = string
  default     = null
  description = "Human-readable description applied to created AgentCore resources."
}

variable "create_runtime_endpoint" {
  type        = bool
  default     = true
  description = "Create a named invoke endpoint for the runtime."
}

variable "runtime_endpoint_version" {
  type        = string
  default     = null
  description = "Pin the runtime endpoint to a specific runtime version. Null leaves it unpinned (tracks latest)."
}

###############################################################################
# Encryption (KMS)
###############################################################################

variable "create_kms_key" {
  type        = bool
  default     = true
  description = "Create a customer-managed KMS key for at-rest encryption."
}

variable "kms_key_arn" {
  type        = string
  default     = null
  description = "Existing CMK ARN to use when create_kms_key = false."
}

variable "enable_key_rotation" {
  type        = bool
  default     = true
  description = "Enable annual rotation on the module-created KMS key."
}

###############################################################################
# Execution roles (IAM)
###############################################################################

variable "create_execution_role" {
  type        = bool
  default     = true
  description = "Create per-component least-privilege execution roles."
}

variable "runtime_execution_role_arn" {
  type        = string
  default     = null
  description = "Existing runtime execution role ARN when create_execution_role = false."
}

variable "gateway_execution_role_arn" {
  type        = string
  default     = null
  description = "Existing gateway execution role ARN."
}

variable "memory_execution_role_arn" {
  type        = string
  default     = null
  description = "Existing memory execution role ARN (required for model-backed CUSTOM strategies)."
}

###############################################################################
# Observability
###############################################################################

variable "enable_observability" {
  type        = bool
  default     = true
  description = "Create CMK-encrypted, retention-bounded CloudWatch log groups and add Logs/Metrics/X-Ray statements to the execution role."
}

variable "log_retention_in_days" {
  type        = number
  default     = 90
  description = "Retention for module-created CloudWatch log groups."

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1827, 3653], var.log_retention_in_days)
    error_message = "log_retention_in_days must be a valid CloudWatch Logs retention value."
  }
}

###############################################################################
# Gateway
###############################################################################

variable "create_gateway" {
  type        = bool
  default     = false
  description = "Create an AgentCore Gateway."
}

variable "gateway_authorizer_type" {
  type        = string
  default     = "AWS_IAM"
  description = "Gateway inbound auth type. Anonymous access is not permitted."

  validation {
    condition     = contains(["AWS_IAM", "CUSTOM_JWT"], var.gateway_authorizer_type)
    error_message = "gateway_authorizer_type must be one of AWS_IAM, CUSTOM_JWT."
  }
}

variable "gateway_jwt_discovery_url" {
  type        = string
  default     = null
  description = "OIDC discovery URL for CUSTOM_JWT gateways."

  validation {
    condition     = var.gateway_jwt_discovery_url == null ? true : can(regex(".*/\\.well-known/openid-configuration$", var.gateway_jwt_discovery_url))
    error_message = "gateway_jwt_discovery_url must end with /.well-known/openid-configuration."
  }
}

variable "gateway_jwt_allowed_audience" {
  type        = list(string)
  default     = []
  description = "Allowed JWT audiences for a CUSTOM_JWT gateway."
}

variable "gateway_jwt_allowed_clients" {
  type        = list(string)
  default     = []
  description = "Allowed JWT client IDs for a CUSTOM_JWT gateway."
}

variable "gateway_protocol_type" {
  type        = string
  default     = null
  description = "Gateway protocol. MCP for tool gateways; null (omitted) required for HTTP-to-runtime targets."

  validation {
    condition     = var.gateway_protocol_type == null ? true : var.gateway_protocol_type == "MCP"
    error_message = "gateway_protocol_type, when set, must equal MCP."
  }
}

variable "gateway_targets" {
  type        = any
  default     = {}
  description = "Map of gateway targets keyed by stable name. Each entry: exactly one of mcp/http; credential_provider_configuration present for lambda/openapi/smithy, absent for unauth mcp_server."
}

###############################################################################
# Memory
###############################################################################

variable "create_memory" {
  type        = bool
  default     = false
  description = "Create an AgentCore Memory store."
}

variable "memory_event_expiry_duration" {
  type        = number
  default     = 90
  description = "Days until memory events expire (finite retention)."

  validation {
    condition     = var.memory_event_expiry_duration >= 7 && var.memory_event_expiry_duration <= 365
    error_message = "memory_event_expiry_duration must be between 7 and 365 days."
  }
}

variable "memory_strategies" {
  type        = any
  default     = {}
  description = "Map of memory strategies keyed by stable name (max 6 per memory)."

  validation {
    condition     = length(var.memory_strategies) <= 6
    error_message = "memory_strategies supports a maximum of 6 strategies per memory."
  }
}

###############################################################################
# Identity
###############################################################################

variable "create_identity" {
  type        = bool
  default     = false
  description = "Provision the customer-managed token-vault CMK and credential providers. Does not gate the implicit workload identity."
}

variable "create_standalone_workload_identity" {
  type        = bool
  default     = false
  description = "Create an explicit standalone workload identity (for custom OAuth2 return URLs)."
}

variable "workload_identity_name" {
  type        = string
  default     = null
  description = "Name for the standalone workload identity."

  validation {
    condition = (
      !var.create_standalone_workload_identity ? true : (
        var.workload_identity_name != null &&
        try(length(var.workload_identity_name) >= 3, false) &&
        try(length(var.workload_identity_name) <= 255, false) &&
        try(can(regex("^[a-zA-Z0-9._-]+$", var.workload_identity_name)), false)
      )
    )
    error_message = "When create_standalone_workload_identity is true, workload_identity_name must be set, 3-255 chars, and match ^[a-zA-Z0-9._-]+$."
  }
}

variable "allowed_resource_oauth2_return_urls" {
  type        = set(string)
  default     = []
  description = "Exact OAuth2 redirect URLs allowed for the standalone workload identity."
}

variable "api_key_credential_providers" {
  type = map(object({
    api_key_wo         = string
    api_key_wo_version = number
  }))
  default     = {}
  sensitive   = true
  description = "Map of API-key credential providers (write-only secret args). Requires create_identity = true."
}

variable "oauth2_credential_providers" {
  type        = any
  default     = {}
  sensitive   = true
  description = "Map of OAuth2 credential providers (write-only secret args). Requires create_identity = true."
}

###############################################################################
# Tagging
###############################################################################

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Tags merged with module defaults onto every taggable resource."
}
