# Changelog

All notable changes to this module are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this module adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-06-09

Initial release of `terraform-aws-agentcore` — an opinionated, secure-by-default
Amazon Bedrock AgentCore stack for teams deploying containerized AI agents.

### Added

- **Always-on agent Runtime** provisioned from a consumer-supplied ECR container
  image URI (`container_uri`), plus an optional named invoke endpoint
  (`create_runtime_endpoint`, default on).
- **Optional Gateway** (`create_gateway`, default off) exposing tools over
  MCP/HTTP with mandatory inbound authentication (`AWS_IAM` or `CUSTOM_JWT`);
  anonymous access is rejected. Supports `for_each` gateway targets with the
  MCP-vs-HTTP `protocol_type` either/or guard.
- **Optional persistent Memory** (`create_memory`, default off) with bounded,
  finite retention (`memory_event_expiry_duration`, 7–365 days, default 90) and
  `for_each` memory strategies (max 6 per memory).
- **Optional Identity primitives** (`create_identity`, default off): a
  customer-managed token-vault CMK plus API-key and OAuth2 outbound credential
  providers, and an optional standalone workload identity.
- **Customer-managed KMS encryption by default** (`create_kms_key`, default on)
  with annual key rotation (`enable_key_rotation`, default on). A single module
  CMK is wired to the Gateway (`kms_key_arn`), Memory (`encryption_key_arn`),
  the Identity token vault (`token_vault_cmk`), and CloudWatch log groups.
  Consumers may supply an existing `kms_key_arn` instead.
- **KMS key policy** granting the AgentCore service principal
  Decrypt/GenerateDataKey*/DescribeKey/CreateGrant, scoped by `kms:ViaService`,
  `kms:CallerAccount`, and `kms:GrantIsForAWSResource` on CreateGrant.
- **Least-privilege per-component IAM execution roles** (`create_execution_role`,
  default on) for Runtime, Gateway, and Memory, each trusting only
  `bedrock-agentcore.amazonaws.com` constrained by `aws:SourceAccount` and
  `aws:SourceArn` confused-deputy guards, with resource-scoped permissions.
  Consumers may supply existing role ARNs instead.
- **CloudWatch observability** (`enable_observability`, default on): CMK-encrypted,
  retention-bounded log groups (`log_retention_in_days`, default 90) plus scoped
  Logs/Metrics/X-Ray statements on the execution roles.
- **Write-only credential arguments** (`*_wo`) for credential providers so API
  keys and OAuth client secrets never enter Terraform state or plan output;
  secret material lands in Secrets Manager encrypted under the token-vault CMK.
- **PUBLIC network mode** (AWS-managed connectivity). The `network_mode` input is
  validated to `PUBLIC` only this iteration but is shaped to accept a future
  `VPC` value without a breaking change.
- **Stable outputs** (ARNs, IDs, endpoint/gateway URLs) for every component,
  resolving to `null`/empty when a component is disabled.
- Provider/Terraform floor pinned with `>=`: `terraform >= 1.8`,
  `hashicorp/aws >= 6.21`.

### Notes

- Container image build and ECR repository management are out of scope; consumers
  supply a ready ECR image URI.
- VPC / private networking is deferred; the module operates in `PUBLIC` mode only.

[Unreleased]: https://github.com/your-org/terraform-aws-agentcore/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/your-org/terraform-aws-agentcore/releases/tag/v0.1.0
