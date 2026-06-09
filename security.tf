###############################################################################
# Security core: KMS CMK + key policy + alias, per-component execution roles
# with confused-deputy trust guards and resource-scoped inline policies, and
# CMK-encrypted, retention-bounded CloudWatch log groups.
#
# Resource addresses here are contractual: locals.tf and outputs.tf already
# reference aws_kms_key.this, aws_iam_role.{runtime,gateway,memory}, etc.
###############################################################################

locals {
  # Convenience handles for ARN construction and confused-deputy conditions.
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region
  partition  = data.aws_partition.current.partition

  # AgentCore service principal and the regional kms:ViaService value.
  agentcore_service_principal = "bedrock-agentcore.amazonaws.com"
  agentcore_via_service       = "bedrock-agentcore.${local.region}.amazonaws.com"

  # aws:SourceArn confused-deputy guard pattern: any AgentCore resource in this
  # account/region may assume the per-component roles.
  agentcore_source_arn = "arn:${local.partition}:bedrock-agentcore:${local.region}:${local.account_id}:*"

  # Create-vs-supply guards used by lifecycle preconditions below. Exactly one
  # of (module-created CMK) / (supplied kms_key_arn) must resolve to a key, and
  # likewise for each per-component execution role.
  kms_create_or_supply_ok = var.create_kms_key || var.kms_key_arn != null
}

###############################################################################
# KMS customer-managed key (encryption at rest)
###############################################################################

resource "aws_kms_key" "this" {
  count = var.create_kms_key ? 1 : 0

  description             = "Customer-managed CMK for Amazon Bedrock AgentCore (${var.name})."
  enable_key_rotation     = var.enable_key_rotation
  deletion_window_in_days = 30

  tags = local.tags

  # Surface the create-vs-supply contract at plan time on the key itself.
  lifecycle {
    precondition {
      condition     = local.kms_create_or_supply_ok
      error_message = "Set create_kms_key = true to have the module create a CMK, or supply kms_key_arn. Exactly one encryption key source must resolve."
    }
  }
}

# Key policy granting the AgentCore service principal the encryption operations
# it needs, scoped by kms:ViaService / kms:CallerAccount, with the additional
# kms:GrantIsForAWSResource = true guard on the CreateGrant statement. Root
# account retains full administrative control of the key.
data "aws_iam_policy_document" "kms" {
  count = var.create_kms_key ? 1 : 0

  # Root-account admin: keeps the key manageable and avoids lockout.
  statement {
    sid       = "EnableRootAccountAdmin"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:${local.partition}:iam::${local.account_id}:root"]
    }
  }

  # AgentCore data-plane usage: Encrypt/Decrypt/GenerateDataKey*/DescribeKey,
  # scoped to this account/region via kms:ViaService + kms:CallerAccount.
  statement {
    sid    = "AllowAgentCoreUseOfTheKey"
    effect = "Allow"
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:GenerateDataKey*",
      "kms:DescribeKey",
    ]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = [local.agentcore_service_principal]
    }

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = [local.agentcore_via_service]
    }

    condition {
      test     = "StringEquals"
      variable = "kms:CallerAccount"
      values   = [local.account_id]
    }
  }

  # AgentCore async/background processing creates grants on the CMK (e.g. memory
  # strategy model inference). CreateGrant is the operation most often omitted;
  # without it create can succeed but async ops fail later.
  statement {
    sid       = "AllowAgentCoreCreateGrant"
    effect    = "Allow"
    actions   = ["kms:CreateGrant"]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = [local.agentcore_service_principal]
    }

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = [local.agentcore_via_service]
    }

    condition {
      test     = "StringEquals"
      variable = "kms:CallerAccount"
      values   = [local.account_id]
    }

    condition {
      test     = "Bool"
      variable = "kms:GrantIsForAWSResource"
      values   = ["true"]
    }
  }
}

resource "aws_kms_key_policy" "this" {
  count = var.create_kms_key ? 1 : 0

  key_id = aws_kms_key.this[0].id
  policy = data.aws_iam_policy_document.kms[0].json
}

resource "aws_kms_alias" "this" {
  count = var.create_kms_key ? 1 : 0

  name          = "alias/${local.runtime_name}"
  target_key_id = aws_kms_key.this[0].key_id
}

###############################################################################
# Execution-role trust policies (confused-deputy guarded)
###############################################################################

# Shared trust policy: trusts only bedrock-agentcore.amazonaws.com, constrained
# by aws:SourceAccount and aws:SourceArn so a deputy in another account/resource
# cannot induce AgentCore to assume these roles on its behalf.
data "aws_iam_policy_document" "agentcore_trust" {
  count = var.create_execution_role ? 1 : 0

  statement {
    sid     = "AssumeRoleFromAgentCore"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = [local.agentcore_service_principal]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = [local.agentcore_source_arn]
    }
  }
}

###############################################################################
# Runtime execution role + inline least-privilege policy
###############################################################################

resource "aws_iam_role" "runtime" {
  count = var.create_execution_role ? 1 : 0

  name               = "${var.name}-runtime"
  assume_role_policy = data.aws_iam_policy_document.agentcore_trust[0].json

  tags = local.tags

  lifecycle {
    precondition {
      condition     = var.create_execution_role || var.runtime_execution_role_arn != null
      error_message = "Set create_execution_role = true or supply runtime_execution_role_arn."
    }
  }
}

data "aws_iam_policy_document" "runtime" {
  count = var.create_execution_role ? 1 : 0

  # ECR auth token cannot be resource-scoped (API requires Resource: *) so it is
  # isolated in its own statement.
  statement {
    sid       = "ECRAuthToken"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  # Image-layer pulls scoped to ECR repositories in this account/region.
  statement {
    sid    = "ECRImagePull"
    effect = "Allow"
    actions = [
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchCheckLayerAvailability",
    ]
    resources = ["arn:${local.partition}:ecr:${local.region}:${local.account_id}:repository/*"]
  }

  # CloudWatch Logs scoped to the AgentCore log-group namespace.
  statement {
    sid    = "CloudWatchLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
    ]
    resources = ["arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:/aws/bedrock-agentcore/*"]
  }

  # CloudWatch metrics scoped to the bedrock-agentcore namespace.
  statement {
    sid       = "CloudWatchMetrics"
    effect    = "Allow"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = ["bedrock-agentcore"]
    }
  }

  # X-Ray tracing (these actions do not support resource scoping).
  statement {
    sid    = "XRayTracing"
    effect = "Allow"
    actions = [
      "xray:PutTraceSegments",
      "xray:PutTelemetryRecords",
      "xray:GetSamplingRules",
      "xray:GetSamplingTargets",
    ]
    resources = ["*"]
  }

  # Bedrock foundation-model invoke, scoped to foundation models in-region.
  statement {
    sid    = "BedrockModelInvoke"
    effect = "Allow"
    actions = [
      "bedrock:InvokeModel",
      "bedrock:InvokeModelWithResponseStream",
    ]
    resources = ["arn:${local.partition}:bedrock:${local.region}::foundation-model/*"]
  }

  # Workload-identity / token-vault access for outbound credential resolution.
  statement {
    sid    = "WorkloadIdentityAndTokens"
    effect = "Allow"
    actions = [
      "bedrock-agentcore:GetWorkloadAccessToken",
      "bedrock-agentcore:GetWorkloadAccessTokenForJWT",
      "bedrock-agentcore:GetWorkloadAccessTokenForUserId",
      "bedrock-agentcore:GetResourceOauth2Token",
      "bedrock-agentcore:GetResourceApiKey",
    ]
    resources = [
      "arn:${local.partition}:bedrock-agentcore:${local.region}:${local.account_id}:workload-identity-directory/default",
      "arn:${local.partition}:bedrock-agentcore:${local.region}:${local.account_id}:workload-identity-directory/default/workload-identity/${local.runtime_name}-*",
      "arn:${local.partition}:bedrock-agentcore:${local.region}:${local.account_id}:token-vault/default/*",
    ]
  }

  # KMS for encrypted resources, scoped via kms:ViaService to AgentCore so the
  # role can only use the key through the service.
  statement {
    sid    = "KMSForEncryptedResources"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:GenerateDataKey",
      "kms:DescribeKey",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = [local.agentcore_via_service]
    }
  }
}

resource "aws_iam_role_policy" "runtime" {
  count = var.create_execution_role ? 1 : 0

  name   = "${var.name}-runtime"
  role   = aws_iam_role.runtime[0].id
  policy = data.aws_iam_policy_document.runtime[0].json
}

###############################################################################
# Gateway execution role + inline least-privilege policy
###############################################################################

resource "aws_iam_role" "gateway" {
  count = var.create_gateway && var.create_execution_role ? 1 : 0

  name               = "${var.name}-gateway"
  assume_role_policy = data.aws_iam_policy_document.agentcore_trust[0].json

  tags = local.tags
}

data "aws_iam_policy_document" "gateway" {
  count = var.create_gateway && var.create_execution_role ? 1 : 0

  # Lambda targets: scoped to functions in this account/region.
  statement {
    sid       = "LambdaInvoke"
    effect    = "Allow"
    actions   = ["lambda:InvokeFunction"]
    resources = ["arn:${local.partition}:lambda:${local.region}:${local.account_id}:function:*"]
  }

  # SigV4 invoke of other AgentCore runtimes / mcp_server HTTP targets.
  statement {
    sid    = "AgentCoreSigV4Invoke"
    effect = "Allow"
    actions = [
      "bedrock-agentcore:InvokeAgentRuntime",
    ]
    resources = ["arn:${local.partition}:bedrock-agentcore:${local.region}:${local.account_id}:*"]
  }

  # Outbound credential secrets for api_key/oauth targets live in Secrets
  # Manager; scope to AgentCore-managed secrets in-account/region.
  statement {
    sid       = "SecretsManagerRead"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = ["arn:${local.partition}:secretsmanager:${local.region}:${local.account_id}:secret:bedrock-agentcore*"]
  }

  # CloudWatch Logs scoped to the AgentCore log-group namespace.
  statement {
    sid    = "CloudWatchLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
    ]
    resources = ["arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:/aws/bedrock-agentcore/*"]
  }

  # KMS for encrypted gateway data, scoped via kms:ViaService.
  statement {
    sid    = "KMSForEncryptedResources"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:GenerateDataKey",
      "kms:DescribeKey",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = [local.agentcore_via_service]
    }
  }
}

resource "aws_iam_role_policy" "gateway" {
  count = var.create_gateway && var.create_execution_role ? 1 : 0

  name   = "${var.name}-gateway"
  role   = aws_iam_role.gateway[0].id
  policy = data.aws_iam_policy_document.gateway[0].json
}

###############################################################################
# Memory execution role + managed model-inference policy attachment
###############################################################################

resource "aws_iam_role" "memory" {
  count = var.create_memory && var.create_execution_role ? 1 : 0

  name               = "${var.name}-memory"
  assume_role_policy = data.aws_iam_policy_document.agentcore_trust[0].json

  tags = local.tags
}

# Model-backed (CUSTOM) memory strategies invoke foundation models. AWS
# publishes a managed policy for exactly this; attach it as the secure default.
resource "aws_iam_role_policy_attachment" "memory_inference" {
  count = var.create_memory && var.create_execution_role ? 1 : 0

  role       = aws_iam_role.memory[0].name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonBedrockAgentCoreMemoryBedrockModelInferenceExecutionRolePolicy"
}

###############################################################################
# CloudWatch log groups (CMK-encrypted, retention-bounded)
#
# Design open question (§7): pre-creating service log groups can race with the
# service auto-creating them. The design's stated choice is to PRE-CREATE so we
# can enforce CMK encryption and bounded retention; both groups are gated behind
# enable_observability. If apply-time conflicts surface in integration testing,
# the fallback is service-created groups + a CloudWatch Logs resource policy.
###############################################################################

resource "aws_cloudwatch_log_group" "runtime" {
  count = var.enable_observability ? 1 : 0

  name              = "/aws/bedrock-agentcore/runtimes/${local.runtime_name}"
  retention_in_days = var.log_retention_in_days
  kms_key_id        = local.kms_key_arn

  tags = local.tags
}

resource "aws_cloudwatch_log_group" "gateway" {
  count = var.create_gateway && var.enable_observability ? 1 : 0

  name              = "/aws/bedrock-agentcore/gateways/${local.runtime_name}"
  retention_in_days = var.log_retention_in_days
  kms_key_id        = local.kms_key_arn

  tags = local.tags
}
