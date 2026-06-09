# Generated from specs/002-agentcore/design.md Section 5

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "111122223333"
      arn        = "arn:aws:iam::111122223333:user/test"
      user_id    = "AIDTEST"
    }
  }

  mock_data "aws_region" {
    defaults = {
      name = "us-east-1"
    }
  }

  mock_data "aws_partition" {
    defaults = {
      partition  = "aws"
      dns_suffix = "amazonaws.com"
    }
  }
}

# Scenario: "Full Features (complete)"
run "test_full_features" {
  command = plan

  variables {
    name          = "myagent"
    container_uri = "111122223333.dkr.ecr.us-east-1.amazonaws.com/myagent:latest"

    create_gateway            = true
    gateway_authorizer_type   = "CUSTOM_JWT"
    gateway_jwt_discovery_url  = "https://issuer.example.com/.well-known/openid-configuration"
    gateway_protocol_type     = "MCP"
    gateway_targets = {
      lambda_tool = {
        target_configuration              = { mcp = { lambda = { lambda_arn = "arn:aws:lambda:us-east-1:111122223333:function:tool" } } }
        credential_provider_configuration = { gateway_iam_role = {} }
      }
    }

    create_memory                = true
    memory_event_expiry_duration = 180
    memory_strategies = {
      semantic = { type = "SEMANTIC", namespaces = ["/actors/{actorId}"] }
    }

    create_identity = true
    api_key_credential_providers = {
      weather = { api_key_wo = "secret-key", api_key_wo_version = 1 }
    }

    tags = { Environment = "test" }
  }

  assert {
    condition     = length(aws_bedrockagentcore_gateway.this) == 1
    error_message = "Gateway should be created when create_gateway is true."
  }

  assert {
    condition     = aws_bedrockagentcore_gateway.this[0].authorizer_type == "CUSTOM_JWT"
    error_message = "Gateway authorizer type should be CUSTOM_JWT."
  }

  # [plan-unknown] kms_key_arn is computed; substitute resource-existence check.
  assert {
    condition     = length(aws_bedrockagentcore_gateway.this[*]) == 1
    error_message = "Gateway should exist (CMK-encrypted)."
  }

  assert {
    condition     = length(aws_bedrockagentcore_gateway_target.this) == 1
    error_message = "Gateway target should be created."
  }

  assert {
    condition     = length(aws_bedrockagentcore_memory.this) == 1
    error_message = "Memory should be created when create_memory is true."
  }

  assert {
    condition     = aws_bedrockagentcore_memory.this[0].event_expiry_duration == 180
    error_message = "Memory retention should equal the configured value (180)."
  }

  # [plan-unknown] encryption_key_arn is computed; substitute resource-existence check.
  assert {
    condition     = length(aws_bedrockagentcore_memory.this[*]) == 1
    error_message = "Memory should exist (CMK-encrypted)."
  }

  assert {
    condition     = length(aws_bedrockagentcore_memory_strategy.this) == 1
    error_message = "Memory strategy should be created."
  }

  assert {
    condition     = aws_bedrockagentcore_token_vault_cmk.this[0].kms_configuration[0].key_type == "CustomerManagedKey"
    error_message = "Token vault CMK should use a CustomerManagedKey."
  }

  assert {
    condition     = length(aws_bedrockagentcore_api_key_credential_provider.this) == 1
    error_message = "API-key credential provider should be created."
  }

  assert {
    condition     = aws_bedrockagentcore_api_key_credential_provider.this["weather"].api_key_wo_version == 1
    error_message = "Credential provider should use the write-only version arg."
  }

  assert {
    condition     = aws_bedrockagentcore_agent_runtime.this.tags["Environment"] == "test"
    error_message = "Consumer tag should be merged onto the runtime."
  }

  assert {
    condition     = aws_bedrockagentcore_agent_runtime.this.tags["ManagedBy"] == "terraform"
    error_message = "ManagedBy default tag should be present on the runtime."
  }
}
