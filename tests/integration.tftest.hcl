# Generated from specs/002-agentcore/design.md Section 5
# integration — real providers, command = apply. End-to-end create/destroy in
# us-east-1 with a real ECR image URI and a real OIDC discovery URL.
# Created but NOT run in this workflow.

# Scenario: "End-to-End" (Full Features inputs, deployed to us-east-1)
run "test_end_to_end" {
  command = apply

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
    condition     = aws_bedrockagentcore_agent_runtime.this.agent_runtime_id != ""
    error_message = "Runtime should be created with a real ID."
  }

  assert {
    condition     = output.gateway_url != null
    error_message = "Gateway URL output should be populated."
  }

  assert {
    condition     = output.memory_arn != null
    error_message = "Memory ARN output should be populated."
  }

  assert {
    condition     = output.token_vault_cmk_key_arn == aws_kms_key.this[0].arn
    error_message = "Token vault CMK should apply the customer-managed key."
  }

  assert {
    condition     = can(regex("^arn:aws:secretsmanager:", output.api_key_secret_arns["weather"]))
    error_message = "API-key secret ARN output should resolve to a Secrets Manager ARN."
  }
}
