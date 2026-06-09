# Module Design: terraform-aws-agentcore

**Branch**: feat/002-agentcore
**Date**: 2026-06-09
**Status**: Draft
**Provider**: hashicorp/aws >= 6.21
**Terraform**: >= 1.8

---

## Table of Contents

1. [Purpose & Requirements](#1-purpose--requirements)
2. [Resources & Architecture](#2-resources--architecture)
3. [Interface Contract](#3-interface-contract)
4. [Security Controls](#4-security-controls)
5. [Test Scenarios](#5-test-scenarios)
6. [Implementation Checklist](#6-implementation-checklist)
7. [Open Questions](#7-open-questions)

---

## 1. Purpose & Requirements

This module provisions a complete, opinionated, secure-by-default Amazon Bedrock AgentCore stack for teams deploying containerized AI agents. It always creates an always-on agent Runtime (from a consumer-supplied container image) and optionally layers on a Gateway (to expose tools over MCP/HTTP), persistent Memory (cross-session agent state with bounded retention), and explicit Identity primitives (a customer-managed token-vault encryption key plus outbound credential providers). Platform and application teams consume it to stand up a governed agent footprint — customer-managed encryption, least-privilege per-component execution roles, and CloudWatch observability — without each consumer re-deriving the IAM, KMS, and confused-deputy guard wiring that AgentCore requires.

**Scope boundary**: The following are explicitly OUT of scope for this iteration:

- **Container image build and ECR repository management** — the consumer supplies a ready ECR image URI (`container_uri`); the module does not build images or manage `aws_ecr_repository`.
- **VPC / private networking** — the module operates in `PUBLIC` (AWS-managed) network mode only. The `network_mode` input is designed so a future `VPC` value can be added without breaking changes, but VPC subnet/security-group wiring is not implemented now.
- **S3 code-zip runtime artifacts** (`code_configuration`) — only `container_configuration` is supported this iteration.
- **Account-level prerequisites** — CloudWatch Transaction Search enablement and Service Quota increases are account/region setup the module flags but does not toggle.
- **Lambda interceptor / Lambda target function source** — the module wires references to consumer-provided Lambda ARNs but does not author interceptor or target Lambda functions.

### Requirements

**Functional requirements** — what the module must do (from Phase 1 clarification):

- The module MUST always provision an agent runtime execution environment from a consumer-provided container image.
- The module MUST optionally provision a gateway, persistent memory, and explicit identity (token-vault encryption + credential providers), each independently toggleable.
- The module MUST default to AWS-managed (public) network connectivity while keeping the network-mode interface forward-compatible with private connectivity.
- The module MUST encrypt all encryptable data at rest under a customer-managed encryption key by default, creating the key itself unless the consumer supplies one.
- The module MUST grant each component its own least-privilege execution identity by default, creating the identity itself unless the consumer supplies one.
- The module MUST emit operational telemetry (logs, metrics, traces) to a managed observability backend by default.
- The module MUST keep credential material (API keys, OAuth client secrets) out of Terraform state and plan output.
- The module MUST enforce authenticated-only inbound access to any gateway it creates.
- The module MUST bound memory retention to a finite, configurable period.
- The module MUST expose stable identifiers (ARNs, IDs, endpoint URLs) for every component, resolving to null when a component is disabled.

**Non-functional requirements** — constraints that bound the design:

- **Provider/Terraform floor**: AgentCore resources require `hashicorp/aws >= 6.21` and `terraform >= 1.8` (write-only credential arguments require Terraform 1.11+ at apply time for the secret-bearing paths).
- **Confused-deputy resistance**: every service-principal trust and key-policy grant MUST be constrained with `aws:SourceAccount` / `aws:SourceArn` (or `kms:ViaService` / `kms:CallerAccount`) conditions.
- **Data minimization / compliance**: memory retention MUST be finite (7–365 days); indefinite retention is not permitted by the service.
- **Least blast radius**: components MUST NOT share a single execution role by default.
- **Regional portability**: the module MUST NOT hardcode a region; consumers confirm AgentCore and referenced foundation models are available in their target region.
- **No provider credentials in the module**: provider auth is inherited from the consumer.

---

## 2. Resources & Architecture

### Architectural Decisions

**Native `aws_bedrockagentcore_*` resources over Cloud Control (`awscc`)**: Use the native AWS provider resource family for the full stack. *Rationale*: every needed primitive (Runtime, Gateway, Memory, Identity) is a first-class managed resource in `hashicorp/aws` v6.49.0 with richer hand-written schemas — write-only secret args, validation, nested custom-claim blocks (research-provider-resources, research-aws-best-practices). *Source*: hashicorp/aws v6.49.0 "Bedrock AgentCore" subcategory. *Rejected*: `awscc_bedrockagentcore_*` Cloud Control types — auto-generated, weaker schemas, no write-only secret args, and there is no capability gap to fill.

**Runtime always-on; Gateway / Memory / Identity optional and default-OFF**: Runtime is created unconditionally; `create_gateway`, `create_memory`, `create_identity` default to `false`. *Rationale*: the canonical public precedent `LuisOsuna117/agentcore/aws` v0.5.1 makes the runtime the always-on reason the module exists and defaults optional features off, matching the `terraform-aws-modules` idiom and least-cost minimal deployments (research-registry-patterns). *Source*: `LuisOsuna117/agentcore/aws` v0.5.1; `terraform-aws-modules/kms/aws` v4.2.0. *Rejected*: always-on components (forces cost/privilege on every consumer); separate per-component top-level modules (pushes cross-component KMS/IAM/ARN wiring onto the consumer).

**`create_identity` governs the token-vault CMK + credential providers, not "whether an identity exists"**: The runtime (and gateway) already emit an implicit `workload_identity_details.workload_identity_arn`. *Rationale*: a workload identity always exists implicitly; the meaningful Identity feature toggle is the customer-managed token-vault encryption key and the outbound credential providers (research-provider-resources, research-registry-patterns). *Source*: `aws_bedrockagentcore_agent_runtime` computed `workload_identity_details`. *Rejected*: treating `create_identity` as gating any identity at all — misleading, since one is always implicitly created.

**Customer-managed KMS created by the module by default, with create-vs-supply toggle and key rotation on**: `create_kms_key` defaults `true`, `enable_key_rotation = true`; consumers may supply `kms_key_arn` instead. *Rationale*: opinionated secure default for auditable, rotatable encryption at rest, matching `terraform-aws-modules/kms` conventions; AWS-managed encryption is the less-controlled fallback (research-aws-best-practices). *Source*: `terraform-aws-modules/kms/aws` v4.2.0 (`enable_key_rotation = true` default); AWS KMS confused-deputy guidance. *Rejected*: AWS-managed encryption everywhere (less control/auditability); no key rotation (weaker key hygiene).

**KMS arg names are non-uniform — wire the single CMK to three distinct attach points**: Gateway top-level `kms_key_arn`; Memory top-level `encryption_key_arn`; Identity via `aws_bedrockagentcore_token_vault_cmk.kms_configuration { key_type = "CustomerManagedKey", kms_key_arn }`; Runtime/endpoint have NO direct KMS arg. *Rationale*: the provider exposes encryption under different argument names per resource and not at all on the runtime (research-provider-resources KMS summary). *Source*: provider docs for `_gateway`, `_memory`, `_token_vault_cmk`. *Rejected*: assuming a uniform `kms_key_arn` everywhere — would fail schema validation on Memory and the token vault.

**KMS key policy MUST grant the AgentCore service principal `kms:CreateGrant` with `kms:ViaService`**: The module-created key policy grants `bedrock-agentcore.amazonaws.com` Decrypt/GenerateDataKey*/DescribeKey/CreateGrant, scoped by `kms:ViaService = bedrock-agentcore.<region>.amazonaws.com`, `kms:CallerAccount`, and `kms:GrantIsForAWSResource = true` on CreateGrant. *Rationale*: AgentCore creates grants for asynchronous/background processing (e.g. memory strategy model inference); omitting CreateGrant lets create succeed but async ops fail later, and omitting the principal entirely causes CreateMemory/CreateGateway AccessDenied (research-aws-best-practices, research-edge-cases §2). *Source*: research-edge-cases §2; AWS confused-deputy guidance. *Rejected*: KMS grants only (some operations validate the key policy; grants don't bootstrap).

**Per-component least-privilege execution roles with confused-deputy guards, create-vs-supply**: `create_execution_role` defaults `true`; each created role trusts `bedrock-agentcore.amazonaws.com` constrained by `aws:SourceAccount` / `aws:SourceArn` and carries image-scoped ECR, scoped CloudWatch Logs/Metrics, X-Ray, scoped Bedrock invoke, workload-identity/token, and scoped KMS statements. *Rationale*: per-component roles limit blast radius; confused-deputy guards prevent cross-account/cross-resource abuse (research-aws-best-practices IAM section). *Source*: research-aws-best-practices IAM policy block; provider examples using `bedrock-agentcore.amazonaws.com`. *Rejected*: single shared role (violates least privilege); bare trust without source guards (confused-deputy exposure).

**Explicit `depends_on` from each AgentCore resource to its IAM policy and KMS key policy**: AgentCore resources reference only `role_arn` / `*_key_arn`, never the policy resources, so Terraform cannot infer ordering. *Rationale*: without explicit ordering the runtime/gateway/memory can be created before permissions/key-policy settle, causing intermittent AccessDenied / image-inspection failures (research-edge-cases §1, §2). *Source*: research-edge-cases §1 (soft dependencies) and §2 (KMS key policy ordering). *Rejected*: implicit ordering only — provider won't order policy-before-create.

**Gateway inbound auth is required (no anonymous); authorizer type and HTTP-target wiring are a strict either/or**: `gateway_authorizer_type ∈ {AWS_IAM, CUSTOM_JWT}`; `CUSTOM_JWT` requires `authorizer_configuration` with a `discovery_url` ending `.well-known/openid-configuration`; HTTP-to-runtime targets require the gateway to have NO `protocol_type` (cannot mix with `protocol_type = MCP`). *Rationale*: AgentCore forbids unauthenticated gateways and forbids HTTP targets on MCP-protocol gateways (research-aws-best-practices Gateway section, research-edge-cases §3). *Source*: provider `_gateway` / `_gateway_target` notes. *Rejected*: exposing an unauthenticated gateway; allowing MCP+HTTP mix (provider rejects it).

**Write-only (`*_wo`) credential arguments for credential providers**: API-key and OAuth2 providers use `api_key_wo`/`api_key_wo_version` and `client_id_wo`/`client_secret_wo`/`client_credentials_wo_version`. *Rationale*: keeps secrets out of state/plan; the plain `api_key`/`client_secret` args leak into state (research-aws-best-practices Identity section, research-edge-cases §5). *Source*: provider `_api_key_credential_provider` / `_oauth2_credential_provider`; Terraform write-only arguments. *Rejected*: plaintext credential args (secret leakage into state/plan).

**Singletons via `count`, collections via `for_each`**: Gateway, Memory, KMS key, IAM roles, token-vault CMK use `count = var.create_* ? 1 : 0`; gateway targets, memory strategies, and credential providers use `for_each` over consumer maps. *Rationale*: `count` is the idiomatic conditional-creation form; `for_each` gives stable addresses for true collections and avoids partial-apply churn (research-registry-patterns; style guide). *Source*: research-registry-patterns composition section. *Rejected*: `for_each` for singletons (non-idiomatic); `count` for collections (unstable addresses).

**Provider pinned with `>=`, not `~>`**: `required_providers { aws = ">= 6.21" }`, `required_version >= 1.8`. *Rationale*: modules use `>=` to maximize consumer compatibility; AgentCore resources floor at 6.21 and are present through 6.49 (research-registry-patterns; constitution §4.1). *Source*: research-registry-patterns provider-pinning section. *Rejected*: `~> 6.0` (over-constrains; `Flaconi/bedrock-agent` does this and it's flagged as an anti-pattern).

### Resource Inventory

| Resource Type | Logical Name | Conditional | Depends On | Key Configuration | Schema Notes |
|---------------|-------------|-------------|------------|-------------------|--------------|
| `aws_kms_key` | `this` | `create_kms_key` (default true) | -- | `enable_key_rotation = true`; module-managed CMK for at-rest encryption | -- |
| `aws_kms_key_policy` | `this` | `create_kms_key` | `aws_kms_key.this` | Grants `bedrock-agentcore.amazonaws.com` Decrypt/GenerateDataKey*/DescribeKey/CreateGrant; conditions `kms:ViaService = bedrock-agentcore.<region>.amazonaws.com`, `kms:CallerAccount`, `kms:GrantIsForAWSResource = true` on CreateGrant; account-root admin | -- |
| `aws_kms_alias` | `this` | `create_kms_key` | `aws_kms_key.this` | `alias/<name>` | -- |
| `aws_iam_role` | `runtime` | `create_execution_role` (default true) | -- | Trust `bedrock-agentcore.amazonaws.com` with `aws:SourceAccount` + `aws:SourceArn` (`arn:aws:bedrock-agentcore:<region>:<account>:*`) | -- |
| `aws_iam_role_policy` | `runtime` | `create_execution_role` | `aws_iam_role.runtime` | Image-scoped ECR pull (+ `ecr:GetAuthorizationToken` on `*` isolated), scoped Logs, namespace-scoped `cloudwatch:PutMetricData`, X-Ray, scoped Bedrock invoke, workload-identity/token, `kms:ViaService`-scoped KMS | -- |
| `aws_iam_role` | `gateway` | `create_gateway && create_execution_role` | -- | Trust `bedrock-agentcore.amazonaws.com` with source guards | -- |
| `aws_iam_role_policy` | `gateway` | `create_gateway && create_execution_role` | `aws_iam_role.gateway` | Scoped `lambda:InvokeFunction`, SigV4 invoke, scoped `secretsmanager:GetSecretValue`, KMS, Logs | -- |
| `aws_iam_role` | `memory` | `create_memory && create_execution_role` | -- | Trust `bedrock-agentcore.amazonaws.com` with source guards; for model-backed strategies | -- |
| `aws_iam_role_policy_attachment` | `memory_inference` | `create_memory && create_execution_role` | `aws_iam_role.memory` | Attaches `AmazonBedrockAgentCoreMemoryBedrockModelInferenceExecutionRolePolicy` | -- |
| `aws_cloudwatch_log_group` | `runtime` | `enable_observability` (default true) | `aws_kms_key.this` | `retention_in_days` (default 90), `kms_key_id` = module CMK | -- |
| `aws_cloudwatch_log_group` | `gateway` | `create_gateway && enable_observability` | `aws_kms_key.this` | `retention_in_days`, CMK-encrypted | -- |
| `aws_bedrockagentcore_agent_runtime` | `this` | always | `aws_iam_role_policy.runtime`, `aws_kms_key_policy.this` | `agent_runtime_name` (hyphens auto-converted to underscores), `role_arn`, `agent_runtime_artifact { container_configuration { container_uri } }`, `network_configuration { network_mode = "PUBLIC" }`, optional `protocol_configuration { server_protocol }`, `environment_variables`; create timeout 30m | `agent_runtime_artifact`, `network_configuration`, `protocol_configuration`, `authorizer_configuration` are single nested blocks (list, index `[0]`); `workload_identity_details` is computed |
| `aws_bedrockagentcore_agent_runtime_endpoint` | `this` | `create_runtime_endpoint` (default true) | `aws_bedrockagentcore_agent_runtime.this` | `name`, `agent_runtime_id` = runtime id; optional `agent_runtime_version` pin (default unpinned) | -- |
| `aws_bedrockagentcore_gateway` | `this` | `create_gateway` | `aws_iam_role_policy.gateway`, `aws_kms_key_policy.this` | `name`, `role_arn`, `authorizer_type` (`AWS_IAM`/`CUSTOM_JWT`), `kms_key_arn` = module CMK, optional `protocol_type = "MCP"` (omitted for HTTP targets), optional `authorizer_configuration`; create timeout 30m | `authorizer_configuration`, `protocol_configuration` are single nested blocks; `workload_identity_details` computed |
| `aws_bedrockagentcore_gateway_target` | `this` | per `gateway_targets` map entry | `aws_bedrockagentcore_gateway.this` | `name`, `gateway_identifier` = gateway id, `target_configuration` (exactly one of `mcp`/`http`), `credential_provider_configuration` (required for lambda/openapi/smithy, omitted for unauth mcp_server) | iterated with `for_each`; `target_configuration`, `credential_provider_configuration` single nested blocks |
| `aws_bedrockagentcore_memory` | `this` | `create_memory` | `aws_kms_key_policy.this`, `aws_iam_role.memory` | `name`, `event_expiry_duration` (7–365, default 90), `encryption_key_arn` = module CMK, optional `memory_execution_role_arn`; outputs plain `arn`/`id`; create/delete timeouts only (no update) | no notable set-typed nested blocks |
| `aws_bedrockagentcore_memory_strategy` | `this` | per `memory_strategies` map entry | `aws_bedrockagentcore_memory.this` | `name`, `memory_id`, `type`, `namespaces` (set), `configuration {}` required only when `type = CUSTOM`; `memory_id`/`type` ForceNew; max 6/memory | `namespaces` is a set (sort or `one()`, never index `[0]`); iterated with `for_each` |
| `aws_bedrockagentcore_workload_identity` | `this` | `create_identity && create_standalone_workload_identity` (default false) | -- | `name` (3–255, alphanumeric `-._`), optional `allowed_resource_oauth2_return_urls` (set) | `allowed_resource_oauth2_return_urls` is a set |
| `aws_bedrockagentcore_token_vault_cmk` | `this` | `create_identity` | `aws_kms_key_policy.this` | `kms_configuration { key_type = "CustomerManagedKey", kms_key_arn = module CMK }`, `token_vault_id = "default"`; delete is state-only (drift) | `kms_configuration` single nested block |
| `aws_bedrockagentcore_api_key_credential_provider` | `this` | per `api_key_credential_providers` map entry (requires `create_identity`) | `aws_bedrockagentcore_token_vault_cmk.this` | `name` (ForceNew), `api_key_wo` + `api_key_wo_version`; secret lands in Secrets Manager (`api_key_secret_arn`) | iterated with `for_each` |
| `aws_bedrockagentcore_oauth2_credential_provider` | `this` | per `oauth2_credential_providers` map entry (requires `create_identity`) | `aws_bedrockagentcore_token_vault_cmk.this` | `name`, `credential_provider_vendor`, `oauth2_provider_config {}`, `client_id_wo`/`client_secret_wo`/`client_credentials_wo_version`; secret in Secrets Manager (`client_secret_arn`) | iterated with `for_each`; `oauth2_provider_config` single nested block |

---

## 3. Interface Contract

### Inputs

| Variable | Type | Required | Default | Validation | Sensitive | Description |
|----------|------|----------|---------|------------|-----------|-------------|
| `name` | `string` | Yes | -- | `length >= 1 && length <= 32`; `^[a-zA-Z][a-zA-Z0-9_-]*$` (must start with a letter) | No | Base name used as a prefix for all resources. Runtime names auto-convert hyphens to underscores. |
| `container_uri` | `string` | Yes | -- | non-empty; `can(regex("\\.dkr\\.ecr\\..*amazonaws\\.com/", var.container_uri))` | No | Consumer-provided ECR container image URI (`<acct>.dkr.ecr.<region>.amazonaws.com/<repo>:<tag>`) for the runtime. |
| `network_mode` | `string` | No | `"PUBLIC"` | `contains(["PUBLIC"], var.network_mode)` | No | Runtime network mode. Only `PUBLIC` supported this iteration; reserved for future `VPC`. |
| `server_protocol` | `string` | No | `"MCP"` | `contains(["HTTP", "MCP", "A2A"], var.server_protocol)` | No | Runtime inbound application protocol. |
| `environment_variables` | `map(string)` | No | `{}` | -- | No | Environment variables injected into the runtime container. |
| `description` | `string` | No | `null` | -- | No | Human-readable description applied to created AgentCore resources. |
| `create_runtime_endpoint` | `bool` | No | `true` | -- | No | Create a named invoke endpoint for the runtime. |
| `runtime_endpoint_version` | `string` | No | `null` | -- | No | Pin the runtime endpoint to a specific runtime version. Null leaves it unpinned (tracks latest). |
| `create_kms_key` | `bool` | No | `true` | -- | No | Create a customer-managed KMS key for at-rest encryption. |
| `kms_key_arn` | `string` | No | `null` | When `create_kms_key = false`, must be non-null (precondition) | No | Existing CMK ARN to use when `create_kms_key = false`. |
| `enable_key_rotation` | `bool` | No | `true` | -- | No | Enable annual rotation on the module-created KMS key. |
| `create_execution_role` | `bool` | No | `true` | -- | No | Create per-component least-privilege execution roles. |
| `runtime_execution_role_arn` | `string` | No | `null` | When `create_execution_role = false`, must be non-null (precondition) | No | Existing runtime execution role ARN when `create_execution_role = false`. |
| `gateway_execution_role_arn` | `string` | No | `null` | When `create_gateway && !create_execution_role`, must be non-null (precondition) | No | Existing gateway execution role ARN. |
| `memory_execution_role_arn` | `string` | No | `null` | When `create_memory && !create_execution_role`, must be non-null (precondition) | No | Existing memory execution role ARN (required for model-backed CUSTOM strategies). |
| `enable_observability` | `bool` | No | `true` | -- | No | Create CMK-encrypted, retention-bounded CloudWatch log groups and add Logs/Metrics/X-Ray statements to the execution role. |
| `log_retention_in_days` | `number` | No | `90` | `contains([1,3,5,7,14,30,60,90,120,150,180,365,400,545,731,1827,3653], var.log_retention_in_days)` | No | Retention for module-created CloudWatch log groups. |
| `create_gateway` | `bool` | No | `false` | -- | No | Create an AgentCore Gateway. |
| `gateway_authorizer_type` | `string` | No | `"AWS_IAM"` | `contains(["AWS_IAM", "CUSTOM_JWT"], var.gateway_authorizer_type)` | No | Gateway inbound auth type. Anonymous access is not permitted. |
| `gateway_jwt_discovery_url` | `string` | No | `null` | When `gateway_authorizer_type = "CUSTOM_JWT"`: non-null and matches `.*/\.well-known/openid-configuration$` (precondition + regex) | No | OIDC discovery URL for `CUSTOM_JWT` gateways. |
| `gateway_jwt_allowed_audience` | `list(string)` | No | `[]` | -- | No | Allowed JWT audiences for a `CUSTOM_JWT` gateway. |
| `gateway_jwt_allowed_clients` | `list(string)` | No | `[]` | -- | No | Allowed JWT client IDs for a `CUSTOM_JWT` gateway. |
| `gateway_protocol_type` | `string` | No | `null` | When set, must equal `"MCP"`; must be null when any `gateway_targets` entry is `http` (precondition) | No | Gateway protocol. `MCP` for tool gateways; null (omitted) required for HTTP-to-runtime targets. |
| `gateway_targets` | `map(object)` | No | `{}` | Each entry: exactly one of `mcp`/`http`; `credential_provider_configuration` present for lambda/openapi/smithy, absent for unauth mcp_server (precondition) | No | Map of gateway targets keyed by stable name. |
| `create_memory` | `bool` | No | `false` | -- | No | Create an AgentCore Memory store. |
| `memory_event_expiry_duration` | `number` | No | `90` | `var.memory_event_expiry_duration >= 7 && var.memory_event_expiry_duration <= 365` | No | Days until memory events expire (finite retention). |
| `memory_strategies` | `map(object)` | No | `{}` | `length(var.memory_strategies) <= 6`; built-in types unique; `configuration` present iff `type == "CUSTOM"` (precondition); each `namespaces` non-empty | No | Map of memory strategies keyed by stable name (max 6 per memory). |
| `create_identity` | `bool` | No | `false` | -- | No | Provision the customer-managed token-vault CMK and credential providers. Does not gate the implicit workload identity. |
| `create_standalone_workload_identity` | `bool` | No | `false` | -- | No | Create an explicit standalone workload identity (for custom OAuth2 return URLs). |
| `workload_identity_name` | `string` | No | `null` | When `create_standalone_workload_identity`: non-null, `length >= 3 && length <= 255`, `^[a-zA-Z0-9._-]+$` | No | Name for the standalone workload identity. |
| `allowed_resource_oauth2_return_urls` | `set(string)` | No | `[]` | -- | No | Exact OAuth2 redirect URLs allowed for the standalone workload identity. |
| `api_key_credential_providers` | `map(object({ api_key_wo = string, api_key_wo_version = number }))` | No | `{}` | -- | Yes | Map of API-key credential providers (write-only secret args). Requires `create_identity = true`. |
| `oauth2_credential_providers` | `map(object)` | No | `{}` | OAuth `AUTHORIZATION_CODE` grant requires `default_return_url` (precondition). Requires `create_identity = true`. | Yes | Map of OAuth2 credential providers (write-only secret args). |
| `tags` | `map(string)` | No | `{}` | -- | No | Tags merged with module defaults onto every taggable resource. |

### Outputs

| Output | Type | Conditional On | Description |
|--------|------|----------------|-------------|
| `agent_runtime_arn` | `string` | always | ARN of the agent runtime. |
| `agent_runtime_id` | `string` | always | ID of the agent runtime. |
| `agent_runtime_version` | `string` | always | Current version of the agent runtime. |
| `agent_runtime_endpoint_arn` | `string` | `create_runtime_endpoint` | ARN of the runtime endpoint; null when not created. |
| `workload_identity_arn` | `string` | always | Implicit workload identity ARN emitted by the runtime. |
| `execution_role_arn` | `string` | always | Runtime execution role ARN (created or supplied). |
| `kms_key_arn` | `string` | always | Effective CMK ARN used for encryption (created or supplied); null if neither. |
| `gateway_arn` | `string` | `create_gateway` | Gateway ARN; null when disabled. |
| `gateway_id` | `string` | `create_gateway` | Gateway ID; null when disabled. |
| `gateway_url` | `string` | `create_gateway` | Gateway MCP/HTTP URL; null when disabled. |
| `gateway_target_ids` | `map(string)` | `create_gateway` | Map of target name to target ID; empty when disabled. |
| `memory_arn` | `string` | `create_memory` | Memory ARN; null when disabled. |
| `memory_id` | `string` | `create_memory` | Memory ID; null when disabled. |
| `memory_strategy_ids` | `map(string)` | `create_memory` | Map of strategy name to strategy ID; empty when disabled. |
| `token_vault_cmk_key_arn` | `string` | `create_identity` | CMK ARN applied to the Identity token vault; null when disabled. |
| `api_key_credential_provider_arns` | `map(string)` | `create_identity` | Map of name to API-key credential provider ARN. |
| `api_key_secret_arns` | `map(string)` | `create_identity` | Map of name to Secrets Manager secret ARN for API-key providers (sensitive). |
| `oauth2_credential_provider_arns` | `map(string)` | `create_identity` | Map of name to OAuth2 credential provider ARN. |
| `oauth2_client_secret_arns` | `map(string)` | `create_identity` | Map of name to Secrets Manager client-secret ARN (sensitive). |
| `standalone_workload_identity_arn` | `string` | `create_standalone_workload_identity` | Standalone workload identity ARN; null when disabled. |

---

## 4. Security Controls

| Control | Enforcement | Configurable? | Reference |
|---------|-------------|---------------|-----------|
| Encryption at rest | Customer-managed KMS CMK created by default (`create_kms_key = true`, `enable_key_rotation = true`) and wired to Gateway (`kms_key_arn`), Memory (`encryption_key_arn`), and the Identity token vault (`token_vault_cmk` with `key_type = "CustomerManagedKey"`); CloudWatch log groups set `kms_key_id`. Encryption is always on — supplying no module key only switches to AWS-managed encryption, never off. | Yes: `create_kms_key` / supply `kms_key_arn` (default secure: module CMK) | CIS AWS 3.8 (KMS rotation); AWS Well-Architected SEC08-BP01 (encryption at rest) |
| Encryption in transit | AgentCore endpoints are HTTPS/TLS via the AWS-managed service; gateway requires authenticated callers over TLS; credential secrets transit to Secrets Manager over TLS. No plaintext transport is exposed by the module. | No: platform-enforced by AgentCore service | AWS Well-Architected SEC09-BP02 (encryption in transit) |
| Public access | `network_mode = "PUBLIC"` is AWS-managed egress, not an open inbound surface; gateway inbound auth is mandatory (`AWS_IAM` or `CUSTOM_JWT`) — anonymous gateways are rejected by validation; runtime invoke requires workload identity/IAM. No 0.0.0.0/0 ingress resource is created. | Yes: `gateway_authorizer_type` (both options authenticated; no "none" option) | AWS Well-Architected SEC03-BP07 (no public/anonymous access); CIS AWS 1.x (auth required) |
| IAM least privilege | Per-component roles (`runtime`/`gateway`/`memory`) trust only `bedrock-agentcore.amazonaws.com` constrained by `aws:SourceAccount` + `aws:SourceArn` confused-deputy guards; permissions are resource-scoped (image-scoped ECR pull, namespace-scoped `cloudwatch:PutMetricData`, model-scoped Bedrock invoke, `kms:ViaService`-scoped KMS, secret-ARN-scoped `secretsmanager:GetSecretValue`); `ecr:GetAuthorizationToken` on `*` isolated because the API requires it. No `*:*`. | Yes: `create_execution_role` / supply role ARNs (default secure: module creates scoped roles) | CIS AWS 1.16/1.22 (no full-admin / least privilege); AWS Well-Architected SEC03-BP02; confused-deputy guidance |
| Logging | `enable_observability = true` creates CMK-encrypted, retention-bounded (`log_retention_in_days`, default 90) CloudWatch log groups and grants the execution role scoped Logs/Metrics/X-Ray permissions; never indefinite retention. | Yes: `enable_observability`, `log_retention_in_days` (default secure: on, 90 days) | CIS AWS 3.4 (CloudWatch logging); AWS Well-Architected SEC04-BP01 (logging & monitoring) |
| Tagging | `tags` merged via `merge(local.module_tags, var.tags)` onto every taggable resource; module defaults include `Name` and `ManagedBy = "terraform"`. | Yes: `tags` (consumer tags take precedence) | Constitution §3.3; AWS Well-Architected SEC01-BP01 (resource governance/tagging) |
| Secret handling | Credential providers use write-only (`*_wo`) args so API keys / OAuth client secrets never enter state or plan; secrets materialize in Secrets Manager encrypted under the token-vault CMK; secret-bearing variables and `*_secret_arn` outputs marked `sensitive = true`. | Yes: providers are opt-in maps (default secure: write-only path only) | AWS Well-Architected SEC02-BP03 (secret management); constitution §3.1 |

---

## 5. Test Scenarios

### Test Strategy

- **Module source**: Tests run against the **root module directly** — no `module {}` blocks in `run` blocks. Assert on `resource_type.resource_name.attribute`.
- **Unit tests**: `mock_provider "aws" {}` with `command = plan`. No `data` sources exist for AgentCore itself (research-provider-resources confirms none), but the KMS key policy / IAM trust use `aws_caller_identity`, `aws_region`, and `aws_partition` data sources — add `mock_data` blocks for these three. Fast, deterministic, no credentials.
- **Acceptance tests**: real providers, `command = plan`. Validate computed ARNs, `workload_identity_details.workload_identity_arn`, gateway URL, and cross-resource references mocks cannot resolve. Created but not run in this workflow.
- **Integration tests**: real providers, `command = apply`. End-to-end create/destroy in `us-east-1` or `us-west-2` (regional availability). Known intermittent IAM-propagation AccessDenied is absorbed by the 30m create timeouts. Created but not run in this workflow.
- **Plan-time limitations**: with mock providers, provider-generated values (ARNs, IDs, endpoints, `gateway_url`) and cross-resource references (e.g. `agent_runtime_id` consumed by the endpoint, `kms_key_arn` read into Gateway/Memory) are unknown. Such assertions are marked `[plan-unknown]`; the test writer substitutes resource-existence/length checks.

### Unit Tests

#### Scenario: Secure Defaults (basic)

**Purpose**: Verify the module works with minimal inputs and security is enabled by default.
**Command**: `plan` (mock providers)

**Inputs**:
```hcl
name          = "myagent"
container_uri = "111122223333.dkr.ecr.us-east-1.amazonaws.com/myagent:latest"
```

**Assertions**:
- Runtime is created — `aws_bedrockagentcore_agent_runtime.this.agent_runtime_name == "myagent"`
- Runtime uses the container image — `aws_bedrockagentcore_agent_runtime.this.agent_runtime_artifact[0].container_configuration[0].container_uri == "111122223333.dkr.ecr.us-east-1.amazonaws.com/myagent:latest"`
- Network mode is PUBLIC — `aws_bedrockagentcore_agent_runtime.this.network_configuration[0].network_mode == "PUBLIC"`
- KMS key is created by default — `length(aws_kms_key.this) == 1`
- Key rotation is enabled — `aws_kms_key.this[0].enable_key_rotation == true`
- Execution role is created by default — `length(aws_iam_role.runtime) == 1`
- Observability log group is created by default — `length(aws_cloudwatch_log_group.runtime) == 1`
- Log group is CMK-encrypted — `aws_cloudwatch_log_group.runtime[0].kms_key_id` is set `[plan-unknown]`
- Log retention is bounded to 90 days — `aws_cloudwatch_log_group.runtime[0].retention_in_days == 90`
- Runtime endpoint is created by default — `length(aws_bedrockagentcore_agent_runtime_endpoint.this) == 1`
- Gateway is NOT created by default — `length(aws_bedrockagentcore_gateway.this) == 0`
- Memory is NOT created by default — `length(aws_bedrockagentcore_memory.this) == 0`
- Token vault CMK is NOT created by default — `length(aws_bedrockagentcore_token_vault_cmk.this) == 0`
- KMS key policy grants CreateGrant to the service — `strcontains(aws_kms_key_policy.this[0].policy, "kms:CreateGrant")` `[plan-unknown]`

#### Scenario: Full Features (complete)

**Purpose**: Verify all features enabled, all optional resources created, all outputs populated.
**Command**: `plan` (mock providers)

**Inputs**:
```hcl
name          = "myagent"
container_uri = "111122223333.dkr.ecr.us-east-1.amazonaws.com/myagent:latest"

create_gateway            = true
gateway_authorizer_type   = "CUSTOM_JWT"
gateway_jwt_discovery_url  = "https://issuer.example.com/.well-known/openid-configuration"
gateway_protocol_type     = "MCP"
gateway_targets = {
  lambda_tool = {
    target_configuration = { mcp = { lambda = { lambda_arn = "arn:aws:lambda:us-east-1:111122223333:function:tool" } } }
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
```

**Assertions**:
- Gateway is created — `length(aws_bedrockagentcore_gateway.this) == 1`
- Gateway authorizer type is CUSTOM_JWT — `aws_bedrockagentcore_gateway.this[0].authorizer_type == "CUSTOM_JWT"`
- Gateway is CMK-encrypted — `aws_bedrockagentcore_gateway.this[0].kms_key_arn` is set `[plan-unknown]`
- Gateway target is created — `length(aws_bedrockagentcore_gateway_target.this) == 1`
- Memory is created — `length(aws_bedrockagentcore_memory.this) == 1`
- Memory retention is the configured value — `aws_bedrockagentcore_memory.this[0].event_expiry_duration == 180`
- Memory is CMK-encrypted — `aws_bedrockagentcore_memory.this[0].encryption_key_arn` is set `[plan-unknown]`
- Memory strategy is created — `length(aws_bedrockagentcore_memory_strategy.this) == 1`
- Token vault CMK uses CustomerManagedKey — `aws_bedrockagentcore_token_vault_cmk.this[0].kms_configuration[0].key_type == "CustomerManagedKey"`
- API-key credential provider is created — `length(aws_bedrockagentcore_api_key_credential_provider.this) == 1`
- Credential provider uses the write-only version arg — `aws_bedrockagentcore_api_key_credential_provider.this["weather"].api_key_wo_version == 1`
- Consumer tag is merged onto the runtime — `aws_bedrockagentcore_agent_runtime.this.tags["Environment"] == "test"`
- ManagedBy default tag is present — `aws_bedrockagentcore_agent_runtime.this.tags["ManagedBy"] == "terraform"`

#### Scenario: Feature Interactions (edge cases)

**Purpose**: Verify non-obvious combinations of feature toggles produce correct behavior.
**Command**: `plan` (mock providers)

**Sub-scenario: Identity disabled suppresses token vault and credential providers**
**Inputs**:
```hcl
name          = "myagent"
container_uri = "111122223333.dkr.ecr.us-east-1.amazonaws.com/myagent:latest"
create_identity = false
api_key_credential_providers = { weather = { api_key_wo = "k", api_key_wo_version = 1 } }
```
**Assertions**:
- Token vault CMK is suppressed — `length(aws_bedrockagentcore_token_vault_cmk.this) == 0`
- API-key credential providers are suppressed when identity is off — `length(aws_bedrockagentcore_api_key_credential_provider.this) == 0`

**Sub-scenario: Supply existing KMS key (create_kms_key = false)**
**Inputs**:
```hcl
name           = "myagent"
container_uri  = "111122223333.dkr.ecr.us-east-1.amazonaws.com/myagent:latest"
create_kms_key = false
kms_key_arn    = "arn:aws:kms:us-east-1:111122223333:key/abcd-1234"
create_memory  = true
```
**Assertions**:
- No module KMS key is created — `length(aws_kms_key.this) == 0`
- Memory uses the supplied key ARN — `aws_bedrockagentcore_memory.this[0].encryption_key_arn == "arn:aws:kms:us-east-1:111122223333:key/abcd-1234"`
- Effective `kms_key_arn` output equals the supplied ARN — `output.kms_key_arn == "arn:aws:kms:us-east-1:111122223333:key/abcd-1234"`

**Sub-scenario: Supply existing execution role (create_execution_role = false)**
**Inputs**:
```hcl
name                       = "myagent"
container_uri              = "111122223333.dkr.ecr.us-east-1.amazonaws.com/myagent:latest"
create_execution_role      = false
runtime_execution_role_arn = "arn:aws:iam::111122223333:role/byo-runtime"
```
**Assertions**:
- No module runtime role is created — `length(aws_iam_role.runtime) == 0`
- Runtime uses the supplied role ARN — `aws_bedrockagentcore_agent_runtime.this.role_arn == "arn:aws:iam::111122223333:role/byo-runtime"`
- `execution_role_arn` output equals the supplied ARN — `output.execution_role_arn == "arn:aws:iam::111122223333:role/byo-runtime"`

**Sub-scenario: Gateway with HTTP-to-runtime target and no protocol_type**
**Inputs**:
```hcl
name                    = "myagent"
container_uri           = "111122223333.dkr.ecr.us-east-1.amazonaws.com/myagent:latest"
create_gateway          = true
gateway_authorizer_type = "AWS_IAM"
gateway_protocol_type   = null
gateway_targets = {
  to_runtime = {
    target_configuration = { http = { agentcore_runtime = { arn = "arn:aws:bedrock-agentcore:us-east-1:111122223333:runtime/r1" } } }
    credential_provider_configuration = { gateway_iam_role = { service = "bedrock-agentcore" } }
  }
}
```
**Assertions**:
- Gateway protocol_type is unset (null) for HTTP targets — `aws_bedrockagentcore_gateway.this[0].protocol_type == null`
- HTTP gateway target is created — `length(aws_bedrockagentcore_gateway_target.this) == 1`

**Sub-scenario: Observability disabled suppresses log groups but module still works**
**Inputs**:
```hcl
name                 = "myagent"
container_uri        = "111122223333.dkr.ecr.us-east-1.amazonaws.com/myagent:latest"
enable_observability = false
```
**Assertions**:
- Runtime log group is suppressed — `length(aws_cloudwatch_log_group.runtime) == 0`
- Runtime is still created — `aws_bedrockagentcore_agent_runtime.this.agent_runtime_name == "myagent"`

**Sub-scenario: Runtime endpoint opt-out**
**Inputs**:
```hcl
name                    = "myagent"
container_uri           = "111122223333.dkr.ecr.us-east-1.amazonaws.com/myagent:latest"
create_runtime_endpoint = false
```
**Assertions**:
- Runtime endpoint is suppressed — `length(aws_bedrockagentcore_agent_runtime_endpoint.this) == 0`
- `agent_runtime_endpoint_arn` output is null — `output.agent_runtime_endpoint_arn == null`

#### Scenario: Validation Boundaries (accept)

**Purpose**: Verify validation rules accept values at the valid boundary.
**Command**: `plan` (mock providers)

**Boundary-pass cases**:
- `memory_event_expiry_duration = 7` (with `create_memory = true`) -> accepted (minimum valid retention) — assert `aws_bedrockagentcore_memory.this[0].event_expiry_duration == 7`
- `memory_event_expiry_duration = 365` (with `create_memory = true`) -> accepted (maximum valid retention) — assert `aws_bedrockagentcore_memory.this[0].event_expiry_duration == 365`
- `name = "a"` -> accepted (minimum length 1, starts with a letter) — assert `aws_bedrockagentcore_agent_runtime.this.agent_runtime_name == "a"`
- `name = "abcdefghij0123456789abcdef0123ab"` (32 chars) -> accepted (maximum length) — assert `aws_bedrockagentcore_agent_runtime.this.agent_runtime_name == "abcdefghij0123456789abcdef0123ab"`
- `workload_identity_name = "abc"` (with `create_identity` + `create_standalone_workload_identity = true`) -> accepted (minimum 3 chars) — assert `length(aws_bedrockagentcore_workload_identity.this) == 1`
- `gateway_authorizer_type = "AWS_IAM"` (with `create_gateway = true`, no JWT discovery URL) -> accepted — assert `aws_bedrockagentcore_gateway.this[0].authorizer_type == "AWS_IAM"`
- `memory_strategies` with exactly 6 entries (one each built-in + customs) -> accepted (max count) — assert `length(aws_bedrockagentcore_memory_strategy.this) == 6`
- `log_retention_in_days = 1` -> accepted (minimum valid CloudWatch retention) — assert `aws_cloudwatch_log_group.runtime[0].retention_in_days == 1`

#### Scenario: Validation Errors (reject)

**Purpose**: Verify input validation rejects bad inputs.
**Command**: `plan` (mock providers)

**Expect error cases**:
- `memory_event_expiry_duration = 6` (with `create_memory = true`) -> rejected ("must be 7-365") — `expect_failures = [var.memory_event_expiry_duration]`
- `memory_event_expiry_duration = 366` (with `create_memory = true`) -> rejected ("must be 7-365") — `expect_failures = [var.memory_event_expiry_duration]`
- `network_mode = "VPC"` -> rejected ("only PUBLIC supported") — `expect_failures = [var.network_mode]`
- `server_protocol = "GRPC"` -> rejected ("must be HTTP/MCP/A2A") — `expect_failures = [var.server_protocol]`
- `gateway_authorizer_type = "NONE"` -> rejected ("must be AWS_IAM/CUSTOM_JWT") — `expect_failures = [var.gateway_authorizer_type]`
- `gateway_authorizer_type = "CUSTOM_JWT"` with `gateway_jwt_discovery_url = null` -> rejected (precondition: discovery URL required) — `expect_failures = [aws_bedrockagentcore_gateway.this]`
- `gateway_jwt_discovery_url = "https://issuer.example.com/openid"` (no `.well-known/openid-configuration`) -> rejected (regex) — `expect_failures = [var.gateway_jwt_discovery_url]`
- `gateway_protocol_type = "MCP"` with an `http` gateway target -> rejected (precondition: HTTP targets require no protocol_type) — `expect_failures = [aws_bedrockagentcore_gateway_target.this]`
- `name = "9bad"` (does not start with a letter) -> rejected (regex) — `expect_failures = [var.name]`
- `create_kms_key = false` with `kms_key_arn = null` -> rejected (precondition: must supply ARN) — `expect_failures = [aws_bedrockagentcore_agent_runtime.this]`
- `create_execution_role = false` with `runtime_execution_role_arn = null` -> rejected (precondition) — `expect_failures = [aws_bedrockagentcore_agent_runtime.this]`
- `memory_strategies` with 7 entries -> rejected ("max 6 strategies") — `expect_failures = [var.memory_strategies]`
- `log_retention_in_days = 17` (not an allowed CloudWatch value) -> rejected — `expect_failures = [var.log_retention_in_days]`

### Acceptance Tests

#### Scenario: Plan Verification

**Purpose**: Verify plan output with real provider APIs — validates computed attributes and provider-resolved references unit tests cannot check.
**Command**: `plan` (real providers) — `# acceptance`

**Inputs**: same as Full Features.

**Assertions**:
- Runtime ARN resolves to a valid format — `can(regex("^arn:aws:bedrock-agentcore:", aws_bedrockagentcore_agent_runtime.this.agent_runtime_arn))`
- Implicit workload identity ARN is populated — `aws_bedrockagentcore_agent_runtime.this.workload_identity_details[0].workload_identity_arn != ""`
- Runtime endpoint references the runtime ID — `aws_bedrockagentcore_agent_runtime_endpoint.this[0].agent_runtime_id == aws_bedrockagentcore_agent_runtime.this.agent_runtime_id`
- Gateway uses the module CMK ARN — `aws_bedrockagentcore_gateway.this[0].kms_key_arn == aws_kms_key.this[0].arn`
- Memory uses the module CMK ARN — `aws_bedrockagentcore_memory.this[0].encryption_key_arn == aws_kms_key.this[0].arn`
- KMS key policy resolves with the service principal — `can(regex("bedrock-agentcore.amazonaws.com", aws_kms_key_policy.this[0].policy))`

### Integration Tests

#### Scenario: End-to-End

**Purpose**: Verify resources are created, configured, and functional in AWS.
**Command**: `apply` (real providers) — `# integration`

**Inputs**: Full Features inputs, deployed to `us-east-1`, with a real ECR image URI and a real OIDC discovery URL.

**Assertions**:
- Runtime is created with a real ID — `aws_bedrockagentcore_agent_runtime.this.agent_runtime_id != ""`
- Gateway URL output is populated — `output.gateway_url != null`
- Memory ARN output is populated — `output.memory_arn != null`
- Token vault CMK applies the customer-managed key — `output.token_vault_cmk_key_arn == aws_kms_key.this[0].arn`
- API-key secret ARN output resolves to a Secrets Manager ARN — `can(regex("^arn:aws:secretsmanager:", output.api_key_secret_arns["weather"]))`

---

## 6. Implementation Checklist

- [x] **A: Scaffold** — Create `versions.tf` (`required_version >= 1.8`, `aws >= 6.21`), `variables.tf` (all inputs with types/validation/sensitivity), `locals.tf` (name normalization with hyphen->underscore for runtime, `merge()` tags, effective KMS/role ARNs), `data.tf` (`aws_caller_identity`, `aws_region`, `aws_partition`), `outputs.tf` (all outputs with `try()` for conditionals). No `provider {}` block.
- [x] **B: Security core** — In `security.tf`: `aws_kms_key` + `aws_kms_key_policy` (service-principal grant with `kms:CreateGrant` + `kms:ViaService`/`CallerAccount`/`GrantIsForAWSResource` conditions) + `aws_kms_alias`; per-component `aws_iam_role` + inline policies with confused-deputy trust guards and resource-scoped permissions; `aws_cloudwatch_log_group`s (CMK-encrypted, retention-bounded). Wire create-vs-supply preconditions.
- [ ] **C: Runtime + features** — In `main.tf`: `aws_bedrockagentcore_agent_runtime` (always-on, `depends_on` IAM policy + KMS key policy) + endpoint; gateway + targets (`for_each`, protocol_type/HTTP-target either-or precondition); memory + strategies (`for_each`, max-6 + CUSTOM-configuration preconditions); identity (`token_vault_cmk`, credential providers with `*_wo` args, optional standalone workload identity). All with `depends_on` to settle IAM/KMS.
- [ ] **D: Examples** — `examples/basic/` (runtime only, minimal inputs, provider config) and `examples/complete/` (gateway + memory + identity, all features, provider config).
- [ ] **E: Tests** — `tests/unit_basic.tftest.hcl`, `unit_complete.tftest.hcl`, `unit_edge_cases.tftest.hcl`, `unit_validation.tftest.hcl` (mock provider + mock_data for caller/region/partition); `tests/acceptance.tftest.hcl` and `tests/integration.tftest.hcl` (real providers, not run here).
- [ ] **F: Polish** — `README.md` via terraform-docs, `CHANGELOG.md`, `terraform fmt`, `terraform validate`, `tflint`, `trivy config .` (no Critical/High).

---

## 7. Open Questions

- **[DEFERRED] Default value of `create_gateway` / `create_memory` / `create_identity`**: The registry-patterns research recommends default-`false` (matching `LuisOsuna117/agentcore/aws` and the `terraform-aws-modules` least-cost-minimal convention), and this design adopts `false`. The clarified scope says "default per the registry-patterns recommendation," so `false` is taken as authoritative — but if the intended UX is "full stack on by default," these three defaults flip to `true`. Confirm at design review.
- **[DEFERRED] Whether to expose a `vpc` / `network_mode_config` block now**: VPC is out of scope this iteration. The design keeps `network_mode` validated to `["PUBLIC"]` only, so adding `"VPC"` plus an optional `network_mode_config` object later is a non-breaking minor change (new optional inputs + widened validation). No VPC inputs are surfaced now. Confirm this forward-compat shape is acceptable rather than pre-declaring (unused) `subnets`/`security_groups` inputs.
- **[DEFERRED] Whether to pre-create gateway/memory CloudWatch log groups or rely on service-created groups**: AgentCore writes to `/aws/bedrock-agentcore/...` log groups it can auto-create. This design pre-creates them to enforce CMK encryption and bounded retention, but pre-creating a group the service also expects to create can race. If apply-time conflicts surface in integration testing, fall back to service-created groups plus a CloudWatch Logs resource policy for CMK/retention. Resolve during Phase 3 integration.
