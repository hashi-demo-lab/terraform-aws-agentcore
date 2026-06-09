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

  # IAM policy documents must render valid JSON so policy validation
  # (aws_kms_key_policy / aws_iam_role assume_role_policy / inline policies)
  # passes at plan time.
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}

# Scenario: "Feature Interactions - Identity disabled suppresses token vault and credential providers"
run "test_identity_disabled_suppresses_credentials" {
  command = plan

  variables {
    name                         = "myagent"
    container_uri                = "111122223333.dkr.ecr.us-east-1.amazonaws.com/myagent:latest"
    create_identity              = false
    api_key_credential_providers = { weather = { api_key_wo = "k", api_key_wo_version = 1 } }
  }

  assert {
    condition     = length(aws_bedrockagentcore_token_vault_cmk.this) == 0
    error_message = "Token vault CMK should be suppressed when identity is disabled."
  }

  assert {
    condition     = length(aws_bedrockagentcore_api_key_credential_provider.this) == 0
    error_message = "API-key credential providers should be suppressed when identity is disabled."
  }
}

# Scenario: "Feature Interactions - Supply existing KMS key (create_kms_key = false)"
run "test_supply_existing_kms_key" {
  command = plan

  variables {
    name           = "myagent"
    container_uri  = "111122223333.dkr.ecr.us-east-1.amazonaws.com/myagent:latest"
    create_kms_key = false
    kms_key_arn    = "arn:aws:kms:us-east-1:111122223333:key/abcd-1234"
    create_memory  = true
  }

  assert {
    condition     = length(aws_kms_key.this) == 0
    error_message = "No module KMS key should be created when create_kms_key is false."
  }

  assert {
    condition     = aws_bedrockagentcore_memory.this[0].encryption_key_arn == "arn:aws:kms:us-east-1:111122223333:key/abcd-1234"
    error_message = "Memory should use the supplied KMS key ARN."
  }

  assert {
    condition     = output.kms_key_arn == "arn:aws:kms:us-east-1:111122223333:key/abcd-1234"
    error_message = "Effective kms_key_arn output should equal the supplied ARN."
  }
}

# Scenario: "Feature Interactions - Supply existing execution role (create_execution_role = false)"
run "test_supply_existing_execution_role" {
  command = plan

  variables {
    name                       = "myagent"
    container_uri              = "111122223333.dkr.ecr.us-east-1.amazonaws.com/myagent:latest"
    create_execution_role      = false
    runtime_execution_role_arn = "arn:aws:iam::111122223333:role/byo-runtime"
  }

  assert {
    condition     = length(aws_iam_role.runtime) == 0
    error_message = "No module runtime role should be created when create_execution_role is false."
  }

  assert {
    condition     = aws_bedrockagentcore_agent_runtime.this.role_arn == "arn:aws:iam::111122223333:role/byo-runtime"
    error_message = "Runtime should use the supplied execution role ARN."
  }

  assert {
    condition     = output.execution_role_arn == "arn:aws:iam::111122223333:role/byo-runtime"
    error_message = "execution_role_arn output should equal the supplied ARN."
  }
}

# Scenario: "Feature Interactions - Gateway with HTTP-to-runtime target and no protocol_type"
run "test_gateway_http_target_no_protocol_type" {
  command = plan

  variables {
    name                    = "myagent"
    container_uri           = "111122223333.dkr.ecr.us-east-1.amazonaws.com/myagent:latest"
    create_gateway          = true
    gateway_authorizer_type = "AWS_IAM"
    gateway_protocol_type   = null
    gateway_targets = {
      to_runtime = {
        target_configuration              = { http = { agentcore_runtime = { arn = "arn:aws:bedrock-agentcore:us-east-1:111122223333:runtime/r1" } } }
        credential_provider_configuration = { gateway_iam_role = { service = "bedrock-agentcore" } }
      }
    }
  }

  # protocol_type is optional+computed; when omitted in config it is UNKNOWN at
  # plan time under the mock provider, so it cannot be asserted directly
  # (terraform test errors on an unknown condition value). Assert on the
  # known-value resource counts instead: the gateway and its HTTP target are
  # both created when protocol_type is unset.
  assert {
    condition     = length(aws_bedrockagentcore_gateway.this) == 1
    error_message = "Gateway should be created for an HTTP target with no protocol_type."
  }

  assert {
    condition     = length(aws_bedrockagentcore_gateway_target.this) == 1
    error_message = "HTTP gateway target should be created."
  }
}

# Scenario: "Feature Interactions - Observability disabled suppresses log groups but module still works"
run "test_observability_disabled" {
  command = plan

  variables {
    name                 = "myagent"
    container_uri        = "111122223333.dkr.ecr.us-east-1.amazonaws.com/myagent:latest"
    enable_observability = false
  }

  assert {
    condition     = length(aws_cloudwatch_log_group.runtime) == 0
    error_message = "Runtime log group should be suppressed when observability is disabled."
  }

  assert {
    condition     = aws_bedrockagentcore_agent_runtime.this.agent_runtime_name == "myagent"
    error_message = "Runtime should still be created when observability is disabled."
  }
}

# Scenario: "Feature Interactions - Runtime endpoint opt-out"
run "test_runtime_endpoint_opt_out" {
  command = plan

  variables {
    name                    = "myagent"
    container_uri           = "111122223333.dkr.ecr.us-east-1.amazonaws.com/myagent:latest"
    create_runtime_endpoint = false
  }

  assert {
    condition     = length(aws_bedrockagentcore_agent_runtime_endpoint.this) == 0
    error_message = "Runtime endpoint should be suppressed when create_runtime_endpoint is false."
  }

  assert {
    condition     = output.agent_runtime_endpoint_arn == null
    error_message = "agent_runtime_endpoint_arn output should be null when the endpoint is not created."
  }
}
