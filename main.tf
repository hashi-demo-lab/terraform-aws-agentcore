###############################################################################
# main.tf — AgentCore runtime (always-on) plus optional gateway, memory, and
# identity features.
#
# Resource addresses here are contractual: outputs.tf and locals.tf already
# reference aws_bedrockagentcore_agent_runtime.this, _gateway.this, _memory.this,
# _token_vault_cmk.this, etc. Soft IAM/KMS ordering (the AgentCore resources only
# reference role_arn / *_key_arn, never the policy resources) is bridged with
# explicit depends_on so permissions and the KMS key policy settle before each
# AgentCore resource is created (research-edge-cases §1, §2).
###############################################################################

###############################################################################
# Runtime (always-on)
###############################################################################

resource "aws_bedrockagentcore_agent_runtime" "this" {
  agent_runtime_name = local.runtime_name
  role_arn           = local.runtime_execution_role_arn
  description        = var.description

  environment_variables = var.environment_variables

  agent_runtime_artifact {
    container_configuration {
      container_uri = var.container_uri
    }
  }

  network_configuration {
    network_mode = var.network_mode
  }

  protocol_configuration {
    server_protocol = var.server_protocol
  }

  tags = local.tags

  # IAM and KMS settle before the runtime: the service inspects the ECR image
  # under the execution role during create, and async ops require the key policy.
  depends_on = [
    aws_iam_role_policy.runtime,
    aws_kms_key_policy.this,
  ]

  lifecycle {
    precondition {
      condition     = var.create_kms_key || var.kms_key_arn != null
      error_message = "Set create_kms_key = true to have the module create a CMK, or supply kms_key_arn."
    }

    precondition {
      condition     = var.create_execution_role || var.runtime_execution_role_arn != null
      error_message = "Set create_execution_role = true or supply runtime_execution_role_arn."
    }
  }
}

resource "aws_bedrockagentcore_agent_runtime_endpoint" "this" {
  count = var.create_runtime_endpoint ? 1 : 0

  name             = local.runtime_name
  agent_runtime_id = aws_bedrockagentcore_agent_runtime.this.agent_runtime_id
  description      = var.description

  agent_runtime_version = var.runtime_endpoint_version

  tags = local.tags
}

###############################################################################
# Gateway + targets
###############################################################################

resource "aws_bedrockagentcore_gateway" "this" {
  count = var.create_gateway ? 1 : 0

  name            = var.name
  role_arn        = local.gateway_execution_role_arn
  authorizer_type = var.gateway_authorizer_type
  protocol_type   = var.gateway_protocol_type
  kms_key_arn     = local.kms_key_arn
  description     = var.description

  dynamic "authorizer_configuration" {
    for_each = var.gateway_authorizer_type == "CUSTOM_JWT" ? [1] : []

    content {
      custom_jwt_authorizer {
        discovery_url    = var.gateway_jwt_discovery_url
        allowed_audience = var.gateway_jwt_allowed_audience
        allowed_clients  = var.gateway_jwt_allowed_clients
      }
    }
  }

  tags = local.tags

  depends_on = [
    aws_iam_role_policy.gateway,
    aws_kms_key_policy.this,
  ]

  lifecycle {
    # CUSTOM_JWT gateways require an OIDC discovery URL (the regex is enforced on
    # the variable; this guards the null case).
    precondition {
      condition     = var.gateway_authorizer_type != "CUSTOM_JWT" || var.gateway_jwt_discovery_url != null
      error_message = "gateway_authorizer_type = CUSTOM_JWT requires gateway_jwt_discovery_url to be set."
    }
  }
}

resource "aws_bedrockagentcore_gateway_target" "this" {
  for_each = { for k, v in var.gateway_targets : k => v if var.create_gateway }

  # Target names must match ^([0-9a-zA-Z][-]?){1,100}$ (no underscores). Allow an
  # explicit name override; otherwise derive a schema-valid name from the map key
  # by converting underscores to hyphens while keeping the key as the address.
  name               = try(each.value.name, replace(each.key, "_", "-"))
  gateway_identifier = aws_bedrockagentcore_gateway.this[0].gateway_id
  description        = try(each.value.description, null)

  target_configuration {
    dynamic "mcp" {
      for_each = try(each.value.target_configuration.mcp, null) != null ? [each.value.target_configuration.mcp] : []

      content {
        dynamic "lambda" {
          for_each = try(mcp.value.lambda, null) != null ? [mcp.value.lambda] : []

          content {
            lambda_arn = lambda.value.lambda_arn

            dynamic "tool_schema" {
              for_each = try(lambda.value.tool_schema, null) != null ? [lambda.value.tool_schema] : []

              content {
                dynamic "inline_payload" {
                  for_each = try(tool_schema.value.inline_payload, null) != null ? [tool_schema.value.inline_payload] : []

                  content {
                    name        = inline_payload.value.name
                    description = inline_payload.value.description

                    input_schema {
                      type        = inline_payload.value.input_schema.type
                      description = try(inline_payload.value.input_schema.description, null)
                    }
                  }
                }
              }
            }
          }
        }

        dynamic "mcp_server" {
          for_each = try(mcp.value.mcp_server, null) != null ? [mcp.value.mcp_server] : []

          content {
            endpoint = mcp_server.value.endpoint
          }
        }
      }
    }

    dynamic "http" {
      for_each = try(each.value.target_configuration.http, null) != null ? [each.value.target_configuration.http] : []

      content {
        dynamic "agentcore_runtime" {
          for_each = try(http.value.agentcore_runtime, null) != null ? [http.value.agentcore_runtime] : []

          content {
            arn       = agentcore_runtime.value.arn
            qualifier = try(agentcore_runtime.value.qualifier, null)
          }
        }
      }
    }
  }

  dynamic "credential_provider_configuration" {
    for_each = try(each.value.credential_provider_configuration, null) != null ? [each.value.credential_provider_configuration] : []

    content {
      dynamic "gateway_iam_role" {
        for_each = try(credential_provider_configuration.value.gateway_iam_role, null) != null ? [credential_provider_configuration.value.gateway_iam_role] : []

        content {
          service = try(gateway_iam_role.value.service, null)
          region  = try(gateway_iam_role.value.region, null)
        }
      }

      dynamic "api_key" {
        for_each = try(credential_provider_configuration.value.api_key, null) != null ? [credential_provider_configuration.value.api_key] : []

        content {
          provider_arn              = api_key.value.provider_arn
          credential_location       = try(api_key.value.credential_location, null)
          credential_parameter_name = try(api_key.value.credential_parameter_name, null)
          credential_prefix         = try(api_key.value.credential_prefix, null)
        }
      }

      dynamic "oauth" {
        for_each = try(credential_provider_configuration.value.oauth, null) != null ? [credential_provider_configuration.value.oauth] : []

        content {
          provider_arn       = oauth.value.provider_arn
          grant_type         = try(oauth.value.grant_type, null)
          default_return_url = try(oauth.value.default_return_url, null)
          scopes             = try(oauth.value.scopes, null)
          custom_parameters  = try(oauth.value.custom_parameters, null)
        }
      }

      dynamic "caller_iam_credentials" {
        for_each = try(credential_provider_configuration.value.caller_iam_credentials, null) != null ? [credential_provider_configuration.value.caller_iam_credentials] : []

        content {
          service = caller_iam_credentials.value.service
          region  = try(caller_iam_credentials.value.region, null)
        }
      }

      dynamic "jwt_passthrough" {
        for_each = try(credential_provider_configuration.value.jwt_passthrough, null) != null ? [1] : []

        content {}
      }
    }
  }

  lifecycle {
    # Strict either/or: an MCP-protocol gateway cannot carry an HTTP-to-runtime
    # target. HTTP targets require the gateway to have NO protocol_type.
    precondition {
      condition     = try(each.value.target_configuration.http, null) == null || var.gateway_protocol_type == null
      error_message = "HTTP gateway targets require gateway_protocol_type to be null (cannot mix with protocol_type = MCP)."
    }

    # Outbound auth either/or: lambda/openapi/smithy require a credential
    # provider; an unauthenticated mcp_server must omit it.
    precondition {
      condition = (
        try(each.value.target_configuration.mcp.mcp_server, null) != null
        ? try(each.value.credential_provider_configuration, null) == null
        : try(each.value.credential_provider_configuration, null) != null
      )
      error_message = "credential_provider_configuration is required for lambda/openapi/smithy targets and must be omitted for an unauthenticated mcp_server target."
    }
  }
}

###############################################################################
# Memory + strategies
###############################################################################

resource "aws_bedrockagentcore_memory" "this" {
  count = var.create_memory ? 1 : 0

  name                  = local.runtime_name
  event_expiry_duration = var.memory_event_expiry_duration
  encryption_key_arn    = local.kms_key_arn
  description           = var.description

  memory_execution_role_arn = local.memory_execution_role_arn

  tags = local.tags

  depends_on = [
    aws_kms_key_policy.this,
    aws_iam_role.memory,
    aws_iam_role_policy_attachment.memory_inference,
  ]
}

resource "aws_bedrockagentcore_memory_strategy" "this" {
  for_each = { for k, v in var.memory_strategies : k => v if var.create_memory }

  name       = each.key
  memory_id  = aws_bedrockagentcore_memory.this[0].id
  type       = each.value.type
  namespaces = each.value.namespaces

  memory_execution_role_arn = local.memory_execution_role_arn

  dynamic "configuration" {
    for_each = try(each.value.configuration, null) != null ? [each.value.configuration] : []

    content {
      type = try(configuration.value.type, "SEMANTIC_OVERRIDE")

      dynamic "consolidation" {
        for_each = try(configuration.value.consolidation, null) != null ? [configuration.value.consolidation] : []

        content {
          append_to_prompt = consolidation.value.append_to_prompt
          model_id         = consolidation.value.model_id
        }
      }

      dynamic "extraction" {
        for_each = try(configuration.value.extraction, null) != null ? [configuration.value.extraction] : []

        content {
          append_to_prompt = extraction.value.append_to_prompt
          model_id         = extraction.value.model_id
        }
      }
    }
  }

  lifecycle {
    # CUSTOM strategies require a configuration block; built-in types must omit
    # it. CUSTOM also needs a memory execution role for model inference.
    precondition {
      condition = (
        each.value.type == "CUSTOM"
        ? try(each.value.configuration, null) != null
        : try(each.value.configuration, null) == null
      )
      error_message = "Memory strategy '${each.key}': configuration is required when type = CUSTOM and must be omitted otherwise."
    }

    precondition {
      condition     = each.value.type != "CUSTOM" || local.memory_execution_role_arn != null
      error_message = "Memory strategy '${each.key}': CUSTOM strategies require a memory execution role (create_execution_role = true or supply memory_execution_role_arn)."
    }
  }
}

###############################################################################
# Identity: token-vault CMK, credential providers, standalone workload identity
###############################################################################

resource "aws_bedrockagentcore_token_vault_cmk" "this" {
  count = var.create_identity ? 1 : 0

  kms_configuration {
    key_type    = "CustomerManagedKey"
    kms_key_arn = local.kms_key_arn
  }

  depends_on = [aws_kms_key_policy.this]
}

resource "aws_bedrockagentcore_api_key_credential_provider" "this" {
  # Iterate over the (non-secret) provider names; the secret values are read by
  # key lookup. for_each cannot take a sensitive collection directly.
  for_each = var.create_identity ? nonsensitive(toset(keys(var.api_key_credential_providers))) : toset([])

  name               = each.key
  api_key_wo         = var.api_key_credential_providers[each.key].api_key_wo
  api_key_wo_version = var.api_key_credential_providers[each.key].api_key_wo_version

  tags = local.tags

  # The token vault CMK must encrypt the Secrets Manager secret from creation.
  depends_on = [aws_bedrockagentcore_token_vault_cmk.this]
}

resource "aws_bedrockagentcore_oauth2_credential_provider" "this" {
  # Iterate over the (non-secret) provider names; secret values via key lookup.
  for_each = var.create_identity ? nonsensitive(toset(keys(var.oauth2_credential_providers))) : toset([])

  name                       = each.key
  credential_provider_vendor = var.oauth2_credential_providers[each.key].credential_provider_vendor

  oauth2_provider_config {
    dynamic "custom_oauth2_provider_config" {
      for_each = try(var.oauth2_credential_providers[each.key].oauth2_provider_config.custom_oauth2_provider_config, null) != null ? [var.oauth2_credential_providers[each.key].oauth2_provider_config.custom_oauth2_provider_config] : []

      content {
        client_id_wo                  = try(custom_oauth2_provider_config.value.client_id_wo, null)
        client_secret_wo              = try(custom_oauth2_provider_config.value.client_secret_wo, null)
        client_credentials_wo_version = try(custom_oauth2_provider_config.value.client_credentials_wo_version, null)

        dynamic "oauth_discovery" {
          for_each = try(custom_oauth2_provider_config.value.oauth_discovery, null) != null ? [custom_oauth2_provider_config.value.oauth_discovery] : []

          content {
            discovery_url = try(oauth_discovery.value.discovery_url, null)
          }
        }
      }
    }

    dynamic "github_oauth2_provider_config" {
      for_each = try(var.oauth2_credential_providers[each.key].oauth2_provider_config.github_oauth2_provider_config, null) != null ? [var.oauth2_credential_providers[each.key].oauth2_provider_config.github_oauth2_provider_config] : []

      content {
        client_id_wo                  = try(github_oauth2_provider_config.value.client_id_wo, null)
        client_secret_wo              = try(github_oauth2_provider_config.value.client_secret_wo, null)
        client_credentials_wo_version = try(github_oauth2_provider_config.value.client_credentials_wo_version, null)
      }
    }

    dynamic "google_oauth2_provider_config" {
      for_each = try(var.oauth2_credential_providers[each.key].oauth2_provider_config.google_oauth2_provider_config, null) != null ? [var.oauth2_credential_providers[each.key].oauth2_provider_config.google_oauth2_provider_config] : []

      content {
        client_id_wo                  = try(google_oauth2_provider_config.value.client_id_wo, null)
        client_secret_wo              = try(google_oauth2_provider_config.value.client_secret_wo, null)
        client_credentials_wo_version = try(google_oauth2_provider_config.value.client_credentials_wo_version, null)
      }
    }
  }

  tags = local.tags

  depends_on = [aws_bedrockagentcore_token_vault_cmk.this]
}

resource "aws_bedrockagentcore_workload_identity" "this" {
  count = var.create_identity && var.create_standalone_workload_identity ? 1 : 0

  name                                = var.workload_identity_name
  allowed_resource_oauth2_return_urls = var.allowed_resource_oauth2_return_urls
}
