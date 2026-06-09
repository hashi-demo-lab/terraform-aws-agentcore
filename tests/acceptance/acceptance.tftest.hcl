# Generated from specs/002-agentcore/design.md Section 5
# acceptance — real providers, command = plan. Validates computed attributes
# and provider-resolved references that mock providers cannot resolve.
# Created but NOT run in this workflow.

# Scenario: "Plan Verification" (inputs: same as Full Features)
run "test_plan_verification" {
  command = plan

  variables {
    name          = "myagent"
    container_uri = "111122223333.dkr.ecr.us-east-1.amazonaws.com/myagent:latest"

    create_gateway            = true
    gateway_authorizer_type   = "CUSTOM_JWT"
    gateway_jwt_discovery_url = "https://issuer.example.com/.well-known/openid-configuration"
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
    condition     = can(regex("^arn:aws:bedrock-agentcore:", aws_bedrockagentcore_agent_runtime.this.agent_runtime_arn))
    error_message = "Runtime ARN should resolve to a valid bedrock-agentcore ARN format."
  }

  assert {
    condition     = aws_bedrockagentcore_agent_runtime.this.workload_identity_details[0].workload_identity_arn != ""
    error_message = "Implicit workload identity ARN should be populated."
  }

  assert {
    condition     = aws_bedrockagentcore_agent_runtime_endpoint.this[0].agent_runtime_id == aws_bedrockagentcore_agent_runtime.this.agent_runtime_id
    error_message = "Runtime endpoint should reference the runtime ID."
  }

  assert {
    condition     = aws_bedrockagentcore_gateway.this[0].kms_key_arn == aws_kms_key.this[0].arn
    error_message = "Gateway should use the module CMK ARN."
  }

  assert {
    condition     = aws_bedrockagentcore_memory.this[0].encryption_key_arn == aws_kms_key.this[0].arn
    error_message = "Memory should use the module CMK ARN."
  }

  assert {
    condition     = can(regex("bedrock-agentcore.amazonaws.com", aws_kms_key_policy.this[0].policy))
    error_message = "KMS key policy should resolve with the AgentCore service principal."
  }
}
