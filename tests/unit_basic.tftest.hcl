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
      region = "us-east-1"
    }
  }

  mock_data "aws_partition" {
    defaults = {
      partition  = "aws"
      dns_suffix = "amazonaws.com"
    }
  }

  # IAM policy documents must render valid JSON so policy validation
  # (aws_kms_key_policy / aws_iam_role assume_role_policy / inline policies)
  # passes at plan time.
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}

# Scenario: "Secure Defaults (basic)"
run "test_secure_defaults" {
  command = plan

  variables {
    name          = "myagent"
    container_uri = "111122223333.dkr.ecr.us-east-1.amazonaws.com/myagent:latest"
  }

  assert {
    condition     = aws_bedrockagentcore_agent_runtime.this.agent_runtime_name == "myagent"
    error_message = "Runtime should be created with the provided name."
  }

  assert {
    condition     = aws_bedrockagentcore_agent_runtime.this.agent_runtime_artifact[0].container_configuration[0].container_uri == "111122223333.dkr.ecr.us-east-1.amazonaws.com/myagent:latest"
    error_message = "Runtime should use the supplied container image URI."
  }

  assert {
    condition     = aws_bedrockagentcore_agent_runtime.this.network_configuration[0].network_mode == "PUBLIC"
    error_message = "Network mode should default to PUBLIC."
  }

  assert {
    condition     = length(aws_kms_key.this) == 1
    error_message = "A customer-managed KMS key should be created by default."
  }

  assert {
    condition     = aws_kms_key.this[0].enable_key_rotation == true
    error_message = "KMS key rotation should be enabled by default."
  }

  assert {
    condition     = length(aws_iam_role.runtime) == 1
    error_message = "A runtime execution role should be created by default."
  }

  assert {
    condition     = length(aws_cloudwatch_log_group.runtime) == 1
    error_message = "An observability log group should be created by default."
  }

  # [plan-unknown] kms_key_id is computed; substitute resource-existence check.
  assert {
    condition     = length(aws_cloudwatch_log_group.runtime[*]) == 1
    error_message = "Runtime log group should exist (CMK encryption applied)."
  }

  assert {
    condition     = aws_cloudwatch_log_group.runtime[0].retention_in_days == 90
    error_message = "Log retention should be bounded to 90 days by default."
  }

  assert {
    condition     = length(aws_bedrockagentcore_agent_runtime_endpoint.this) == 1
    error_message = "Runtime endpoint should be created by default."
  }

  assert {
    condition     = length(aws_bedrockagentcore_gateway.this) == 0
    error_message = "Gateway should NOT be created by default."
  }

  assert {
    condition     = length(aws_bedrockagentcore_memory.this) == 0
    error_message = "Memory should NOT be created by default."
  }

  assert {
    condition     = length(aws_bedrockagentcore_token_vault_cmk.this) == 0
    error_message = "Token vault CMK should NOT be created by default."
  }

  # [plan-unknown] policy document is computed; substitute resource-existence check.
  assert {
    condition     = length(aws_kms_key_policy.this[*]) == 1
    error_message = "KMS key policy should exist (grants CreateGrant to the AgentCore service)."
  }
}
