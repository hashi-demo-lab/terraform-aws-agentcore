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

###############################################################################
# Validation Errors (reject)
###############################################################################

# Scenario: "Validation Errors - memory_event_expiry_duration = 6 rejected"
run "test_reject_memory_expiry_below_min" {
  command = plan

  variables {
    name                         = "myagent"
    container_uri                = "111122223333.dkr.ecr.us-east-1.amazonaws.com/myagent:latest"
    create_memory                = true
    memory_event_expiry_duration = 6
  }

  expect_failures = [var.memory_event_expiry_duration]
}

# Scenario: "Validation Errors - memory_event_expiry_duration = 366 rejected"
run "test_reject_memory_expiry_above_max" {
  command = plan

  variables {
    name                         = "myagent"
    container_uri                = "111122223333.dkr.ecr.us-east-1.amazonaws.com/myagent:latest"
    create_memory                = true
    memory_event_expiry_duration = 366
  }

  expect_failures = [var.memory_event_expiry_duration]
}

# Scenario: "Validation Errors - network_mode = VPC rejected"
run "test_reject_network_mode_vpc" {
  command = plan

  variables {
    name          = "myagent"
    container_uri = "111122223333.dkr.ecr.us-east-1.amazonaws.com/myagent:latest"
    network_mode  = "VPC"
  }

  expect_failures = [var.network_mode]
}

# Scenario: "Validation Errors - server_protocol = GRPC rejected"
run "test_reject_server_protocol_grpc" {
  command = plan

  variables {
    name            = "myagent"
    container_uri   = "111122223333.dkr.ecr.us-east-1.amazonaws.com/myagent:latest"
    server_protocol = "GRPC"
  }

  expect_failures = [var.server_protocol]
}

# Scenario: "Validation Errors - gateway_authorizer_type = NONE rejected"
run "test_reject_gateway_authorizer_none" {
  command = plan

  variables {
    name                    = "myagent"
    container_uri           = "111122223333.dkr.ecr.us-east-1.amazonaws.com/myagent:latest"
    create_gateway          = true
    gateway_authorizer_type = "NONE"
  }

  expect_failures = [var.gateway_authorizer_type]
}

# Scenario: "Validation Errors - CUSTOM_JWT without discovery URL rejected (precondition)"
run "test_reject_custom_jwt_missing_discovery_url" {
  command = plan

  variables {
    name                      = "myagent"
    container_uri             = "111122223333.dkr.ecr.us-east-1.amazonaws.com/myagent:latest"
    create_gateway            = true
    gateway_authorizer_type   = "CUSTOM_JWT"
    gateway_jwt_discovery_url  = null
  }

  expect_failures = [aws_bedrockagentcore_gateway.this]
}

# Scenario: "Validation Errors - discovery URL without .well-known/openid-configuration rejected (regex)"
run "test_reject_invalid_discovery_url" {
  command = plan

  variables {
    name                      = "myagent"
    container_uri             = "111122223333.dkr.ecr.us-east-1.amazonaws.com/myagent:latest"
    create_gateway            = true
    gateway_authorizer_type   = "CUSTOM_JWT"
    gateway_jwt_discovery_url  = "https://issuer.example.com/openid"
  }

  expect_failures = [var.gateway_jwt_discovery_url]
}

# Scenario: "Validation Errors - protocol_type = MCP with http target rejected (precondition)"
run "test_reject_mcp_protocol_with_http_target" {
  command = plan

  variables {
    name                    = "myagent"
    container_uri           = "111122223333.dkr.ecr.us-east-1.amazonaws.com/myagent:latest"
    create_gateway          = true
    gateway_authorizer_type = "AWS_IAM"
    gateway_protocol_type   = "MCP"
    gateway_targets = {
      to_runtime = {
        target_configuration              = { http = { agentcore_runtime = { arn = "arn:aws:bedrock-agentcore:us-east-1:111122223333:runtime/r1" } } }
        credential_provider_configuration = { gateway_iam_role = { service = "bedrock-agentcore" } }
      }
    }
  }

  expect_failures = [aws_bedrockagentcore_gateway_target.this]
}

# Scenario: "Validation Errors - name does not start with a letter rejected (regex)"
run "test_reject_name_not_starting_with_letter" {
  command = plan

  variables {
    name          = "9bad"
    container_uri = "111122223333.dkr.ecr.us-east-1.amazonaws.com/myagent:latest"
  }

  expect_failures = [var.name]
}

# Scenario: "Validation Errors - create_kms_key = false with kms_key_arn = null rejected (precondition)"
run "test_reject_kms_supply_missing_arn" {
  command = plan

  variables {
    name           = "myagent"
    container_uri  = "111122223333.dkr.ecr.us-east-1.amazonaws.com/myagent:latest"
    create_kms_key = false
    kms_key_arn    = null
  }

  expect_failures = [aws_bedrockagentcore_agent_runtime.this]
}

# Scenario: "Validation Errors - create_execution_role = false with runtime_execution_role_arn = null rejected (precondition)"
run "test_reject_role_supply_missing_arn" {
  command = plan

  variables {
    name                       = "myagent"
    container_uri              = "111122223333.dkr.ecr.us-east-1.amazonaws.com/myagent:latest"
    create_execution_role      = false
    runtime_execution_role_arn = null
  }

  expect_failures = [aws_bedrockagentcore_agent_runtime.this]
}

# Scenario: "Validation Errors - memory_strategies with 7 entries rejected (max 6)"
run "test_reject_too_many_memory_strategies" {
  command = plan

  variables {
    name          = "myagent"
    container_uri = "111122223333.dkr.ecr.us-east-1.amazonaws.com/myagent:latest"
    create_memory = true
    memory_strategies = {
      s1 = { type = "SEMANTIC", namespaces = ["/a"] }
      s2 = { type = "CUSTOM", namespaces = ["/b"], configuration = {} }
      s3 = { type = "CUSTOM", namespaces = ["/c"], configuration = {} }
      s4 = { type = "CUSTOM", namespaces = ["/d"], configuration = {} }
      s5 = { type = "CUSTOM", namespaces = ["/e"], configuration = {} }
      s6 = { type = "CUSTOM", namespaces = ["/f"], configuration = {} }
      s7 = { type = "CUSTOM", namespaces = ["/g"], configuration = {} }
    }
  }

  expect_failures = [var.memory_strategies]
}

# Scenario: "Validation Errors - log_retention_in_days = 17 rejected (not an allowed value)"
run "test_reject_invalid_log_retention" {
  command = plan

  variables {
    name                  = "myagent"
    container_uri         = "111122223333.dkr.ecr.us-east-1.amazonaws.com/myagent:latest"
    log_retention_in_days = 17
  }

  expect_failures = [var.log_retention_in_days]
}

###############################################################################
# --- Boundary-pass cases (validation accepts) ---
###############################################################################

# Scenario: "Validation Boundaries - memory_event_expiry_duration = 7 accepted (minimum)"
run "test_accept_memory_expiry_min" {
  command = plan

  variables {
    name                         = "myagent"
    container_uri                = "111122223333.dkr.ecr.us-east-1.amazonaws.com/myagent:latest"
    create_memory                = true
    memory_event_expiry_duration = 7
  }

  assert {
    condition     = aws_bedrockagentcore_memory.this[0].event_expiry_duration == 7
    error_message = "Minimum valid memory retention (7 days) should be accepted."
  }
}

# Scenario: "Validation Boundaries - memory_event_expiry_duration = 365 accepted (maximum)"
run "test_accept_memory_expiry_max" {
  command = plan

  variables {
    name                         = "myagent"
    container_uri                = "111122223333.dkr.ecr.us-east-1.amazonaws.com/myagent:latest"
    create_memory                = true
    memory_event_expiry_duration = 365
  }

  assert {
    condition     = aws_bedrockagentcore_memory.this[0].event_expiry_duration == 365
    error_message = "Maximum valid memory retention (365 days) should be accepted."
  }
}

# Scenario: "Validation Boundaries - name = a accepted (minimum length, starts with letter)"
run "test_accept_name_min_length" {
  command = plan

  variables {
    name          = "a"
    container_uri = "111122223333.dkr.ecr.us-east-1.amazonaws.com/myagent:latest"
  }

  assert {
    condition     = aws_bedrockagentcore_agent_runtime.this.agent_runtime_name == "a"
    error_message = "Minimum-length name (1 char, starts with letter) should be accepted."
  }
}

# Scenario: "Validation Boundaries - name = 32 chars accepted (maximum length)"
run "test_accept_name_max_length" {
  command = plan

  variables {
    name          = "abcdefghij0123456789abcdef0123ab"
    container_uri = "111122223333.dkr.ecr.us-east-1.amazonaws.com/myagent:latest"
  }

  assert {
    condition     = aws_bedrockagentcore_agent_runtime.this.agent_runtime_name == "abcdefghij0123456789abcdef0123ab"
    error_message = "Maximum-length name (32 chars) should be accepted."
  }
}

# Scenario: "Validation Boundaries - workload_identity_name = abc accepted (minimum 3 chars)"
run "test_accept_workload_identity_name_min" {
  command = plan

  variables {
    name                                = "myagent"
    container_uri                       = "111122223333.dkr.ecr.us-east-1.amazonaws.com/myagent:latest"
    create_identity                     = true
    create_standalone_workload_identity = true
    workload_identity_name              = "abc"
  }

  assert {
    condition     = length(aws_bedrockagentcore_workload_identity.this) == 1
    error_message = "Minimum-length workload identity name (3 chars) should be accepted."
  }
}

# Scenario: "Validation Boundaries - gateway_authorizer_type = AWS_IAM accepted (no JWT discovery URL)"
run "test_accept_gateway_aws_iam" {
  command = plan

  variables {
    name                    = "myagent"
    container_uri           = "111122223333.dkr.ecr.us-east-1.amazonaws.com/myagent:latest"
    create_gateway          = true
    gateway_authorizer_type = "AWS_IAM"
  }

  assert {
    condition     = aws_bedrockagentcore_gateway.this[0].authorizer_type == "AWS_IAM"
    error_message = "AWS_IAM authorizer without a JWT discovery URL should be accepted."
  }
}

# Scenario: "Validation Boundaries - memory_strategies with exactly 6 entries accepted (max count)"
run "test_accept_six_memory_strategies" {
  command = plan

  variables {
    name          = "myagent"
    container_uri = "111122223333.dkr.ecr.us-east-1.amazonaws.com/myagent:latest"
    create_memory = true
    memory_strategies = {
      s1 = { type = "SEMANTIC", namespaces = ["/a"] }
      s2 = { type = "CUSTOM", namespaces = ["/b"], configuration = {} }
      s3 = { type = "CUSTOM", namespaces = ["/c"], configuration = {} }
      s4 = { type = "CUSTOM", namespaces = ["/d"], configuration = {} }
      s5 = { type = "CUSTOM", namespaces = ["/e"], configuration = {} }
      s6 = { type = "CUSTOM", namespaces = ["/f"], configuration = {} }
    }
  }

  assert {
    condition     = length(aws_bedrockagentcore_memory_strategy.this) == 6
    error_message = "Exactly 6 memory strategies (the maximum) should be accepted."
  }
}

# Scenario: "Validation Boundaries - log_retention_in_days = 1 accepted (minimum valid value)"
run "test_accept_log_retention_min" {
  command = plan

  variables {
    name                  = "myagent"
    container_uri         = "111122223333.dkr.ecr.us-east-1.amazonaws.com/myagent:latest"
    log_retention_in_days = 1
  }

  assert {
    condition     = aws_cloudwatch_log_group.runtime[0].retention_in_days == 1
    error_message = "Minimum valid CloudWatch retention (1 day) should be accepted."
  }
}
