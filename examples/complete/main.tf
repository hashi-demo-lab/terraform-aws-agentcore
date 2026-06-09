###############################################################################
# Complete example — all features enabled.
#
# Runtime + gateway (CUSTOM_JWT, MCP) with a lambda tool target, memory with a
# built-in SEMANTIC strategy, and identity (token-vault CMK + API-key and OAuth2
# credential providers). All inputs use placeholder-but-valid ARNs/URIs.
###############################################################################

module "agentcore" {
  source = "../../"

  name          = "complete-agent"
  container_uri = "111122223333.dkr.ecr.us-east-1.amazonaws.com/complete-agent:latest"
  description   = "AgentCore runtime with gateway, memory, and identity enabled."

  ###########################################################################
  # Gateway (MCP) with a lambda tool target
  ###########################################################################
  create_gateway               = true
  gateway_authorizer_type      = "CUSTOM_JWT"
  gateway_jwt_discovery_url    = "https://issuer.example.com/.well-known/openid-configuration"
  gateway_jwt_allowed_audience = ["agentcore-gateway"]
  gateway_protocol_type        = "MCP"

  gateway_targets = {
    lambda_tool = {
      description = "Lambda-backed MCP tool."
      target_configuration = {
        mcp = {
          lambda = {
            lambda_arn = "arn:aws:lambda:us-east-1:111122223333:function:agent-tool"
            tool_schema = {
              inline_payload = {
                name        = "lookup_weather"
                description = "Look up the weather for a city."
                input_schema = {
                  type        = "object"
                  description = "City lookup request."
                }
              }
            }
          }
        }
      }
      credential_provider_configuration = {
        gateway_iam_role = {}
      }
    }
  }

  ###########################################################################
  # Memory with a built-in SEMANTIC strategy
  ###########################################################################
  create_memory                = true
  memory_event_expiry_duration = 180

  memory_strategies = {
    semantic = {
      type       = "SEMANTIC"
      namespaces = ["/actors/{actorId}"]
    }
  }

  ###########################################################################
  # Identity: token-vault CMK + credential providers
  ###########################################################################
  create_identity = true

  api_key_credential_providers = {
    weather = {
      api_key_wo         = "placeholder-api-key"
      api_key_wo_version = 1
    }
  }

  oauth2_credential_providers = {
    github = {
      credential_provider_vendor = "GithubOauth2"
      oauth2_provider_config = {
        github_oauth2_provider_config = {
          client_id_wo                  = "placeholder-client-id"
          client_secret_wo              = "placeholder-client-secret"
          client_credentials_wo_version = 1
        }
      }
    }
  }

  tags = {
    Environment = "example"
    Project     = "agentcore-complete"
  }
}
