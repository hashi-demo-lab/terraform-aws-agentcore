# Research: AWS Provider Resources for Amazon Bedrock AgentCore (Runtime, Gateway, Memory, Identity)

**Provider:** `hashicorp/aws` **version 6.49.0** (latest at time of research, 2026-06-09)
**Service subcategory:** "Bedrock AgentCore"
**FEATURE:** 002-agentcore (module `terraform-aws-agentcore`)

## Decision

Use the **native `aws_bedrockagentcore_*` resources** in the `hashicorp/aws` provider (v6.49.0+) for the full stack. All four primitives the module needs — Runtime, Gateway, Memory, Identity — are available as first-class managed resources. There is **no need to fall back to the `awscc` provider**; the native AWS provider has richer, hand-written schemas (write-only credential args, validation, nested blocks) than the auto-generated CloudFormation-backed `awscc_bedrockagentcore_*` types.

## Resource Inventory (all `aws_bedrockagentcore_*` in v6.49.0)

| Resource | Relevant to module | Purpose |
|---|---|---|
| `aws_bedrockagentcore_agent_runtime` | **YES (Runtime)** | Containerized agent execution environment |
| `aws_bedrockagentcore_agent_runtime_endpoint` | **YES (Runtime endpoint)** | Network-accessible endpoint for a runtime |
| `aws_bedrockagentcore_gateway` | **YES (Gateway)** | Converts APIs/Lambda/services into MCP tools |
| `aws_bedrockagentcore_gateway_target` | **YES (Gateway target)** | Defines endpoints a gateway can invoke |
| `aws_bedrockagentcore_memory` | **YES (Memory)** | Persistent storage for agent interactions |
| `aws_bedrockagentcore_memory_strategy` | Optional (Memory) | Defines memory processing strategy (semantic/summary/etc.) |
| `aws_bedrockagentcore_workload_identity` | **YES (Identity)** | OAuth2 workload identity for agents |
| `aws_bedrockagentcore_api_key_credential_provider` | **YES (Identity)** | API-key credential provider |
| `aws_bedrockagentcore_oauth2_credential_provider` | **YES (Identity)** | OAuth2/OIDC credential provider |
| `aws_bedrockagentcore_token_vault_cmk` | **YES (KMS/Identity)** | Sets CMK on the account token vault |
| `aws_bedrockagentcore_browser` | No | Browser tool primitive |
| `aws_bedrockagentcore_code_interpreter` | No | Code interpreter tool primitive |
| `aws_bedrockagentcore_harness` | No | Harness primitive |
| `aws_bedrockagentcore_online_evaluation_config` | No | Online evaluation config |
| `aws_bedrockagentcore_policy_engine` | No | Policy engine primitive |
| `aws_bedrockagentcore_resource_policy` | No | Resource-based policy |

**Data sources:** NONE. There are no `aws_bedrockagentcore_*` data sources in v6.49.0. Cross-resource references must use resource attributes (e.g. `agent_runtime_arn`) rather than lookups.

---

## Runtime — `aws_bedrockagentcore_agent_runtime`

Doc: https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/bedrockagentcore_agent_runtime

### Required arguments
- `agent_runtime_name` (string) — name of the runtime.
- `role_arn` (string) — **IAM execution role ARN**. Trust policy must allow `bedrock-agentcore.amazonaws.com` to `sts:AssumeRole`. For an ECR image it needs `ecr:GetAuthorizationToken` (on `*`) plus `ecr:BatchGetImage` / `ecr:GetDownloadUrlForLayer` on the repo ARN.
- `agent_runtime_artifact` (block, required) — the code/container source. Exactly one of:
  - `container_configuration { container_uri = "<ecr-uri>:tag" }` — **this is the consumer-provided ECR image path** the module targets.
  - `code_configuration { entry_point=[...], runtime="PYTHON_3_13", code { s3 { bucket, prefix, version_id } } }` — S3 zip alternative (runtime valid values `PYTHON_3_10|3_11|3_12|3_13`).
- `network_configuration` (block, required) — see below.

### Network mode shape (PUBLIC vs VPC)
```hcl
network_configuration {
  network_mode = "PUBLIC"   # Required. Valid: "PUBLIC", "VPC"
  # network_mode_config only used when network_mode = "VPC":
  # network_mode_config {
  #   security_groups = [...]   # Required for VPC
  #   subnets         = [...]   # Required for VPC
  # }
}
```
For this module (PUBLIC / AWS-managed), set `network_mode = "PUBLIC"` and **omit** `network_mode_config`.

### Key optional arguments
- `description` (string)
- `environment_variables` (map(string)) — container env vars.
- `protocol_configuration { server_protocol = "HTTP" | "MCP" | "A2A" }` — defaults vary; set `MCP` for MCP servers.
- `authorizer_configuration { custom_jwt_authorizer { discovery_url, allowed_audience, allowed_clients, allowed_scopes, custom_claim {...} } }` — inbound request auth. `discovery_url` must end with `.well-known/openid-configuration`.
- `filesystem_configuration` (list, up to 5) — each entry exactly one of `session_storage`, `s3_files_access_point`, `efs_access_point` (each with a `/mnt/<dir>` `mount_path`).
- `lifecycle_configuration { idle_runtime_session_timeout, max_lifetime }` (seconds).
- `request_header_configuration { request_header_allowlist = [...] }`
- `tags` (map)

### KMS / encryption
**No `kms_key_arn` argument on the runtime.** The runtime does not expose customer-managed encryption directly. Customer-managed KMS for the Identity/credential layer is set account-wide via `aws_bedrockagentcore_token_vault_cmk` (see below).

### Computed attributes (outputs)
- `agent_runtime_arn` (string)
- `agent_runtime_id` (string) — used by the endpoint and import.
- `agent_runtime_version` (string)
- `workload_identity_details.workload_identity_arn` (string) — auto-created workload identity ARN.
- `tags_all`

### Constraints
- Import by `agent_runtime_id`. Timeouts create/update/delete default 30m.

---

## Runtime Endpoint — `aws_bedrockagentcore_agent_runtime_endpoint`

Doc: https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/bedrockagentcore_agent_runtime_endpoint

### Required arguments
- `name` (string)
- `agent_runtime_id` (string) — reference `aws_bedrockagentcore_agent_runtime.this.agent_runtime_id`.

### Optional
- `agent_runtime_version` (string) — pin a specific runtime version.
- `description`, `tags`, `region`.

### Computed attributes
- `agent_runtime_endpoint_arn` (string)
- `agent_runtime_arn` (string)
- `tags_all`

No KMS arg. Import id format: `<agent_runtime_id>,<name>`.

---

## Gateway — `aws_bedrockagentcore_gateway`

Doc: https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/bedrockagentcore_gateway

### Required arguments
- `name` (string)
- `role_arn` (string) — **gateway IAM role** (trust `bedrock-agentcore.amazonaws.com`).
- `authorizer_type` (string) — `CUSTOM_JWT` or `AWS_IAM`. If `CUSTOM_JWT`, `authorizer_configuration` is required.

### Key optional arguments
- `authorizer_configuration { custom_jwt_authorizer { discovery_url (required), allowed_audience, allowed_clients, allowed_scopes, custom_claim {...} } }`
- `protocol_type` (string) — valid value `MCP`. **Omit** to create a gateway that routes directly to HTTP targets (e.g. an AgentCore Runtime via `gateway_target.target_configuration.http`). HTTP targets require `protocol_type` to be unset.
- `protocol_configuration { mcp { instructions, search_type ("SEMANTIC"/"HYBRID"), supported_versions=[...], session_configuration { session_timeout_in_seconds (900-28800) }, streaming_configuration { enable_response_streaming } } }`
- `kms_key_arn` (string) — **customer-managed KMS key for gateway data encryption.** This is where CMK is wired on the gateway.
- `interceptor_configuration` (1-2 blocks) — `interception_points = ["REQUEST","RESPONSE"]`, `interceptor { lambda { arn } }`, `input_configuration { pass_request_headers }`.
- `exception_level` (string) — `DEBUG`.
- `description`, `tags`, `region`.

### KMS / encryption
- `kms_key_arn` (optional, top-level) — set this to the consumer-provided customer-managed KMS key ARN.

### Computed attributes (outputs)
- `gateway_arn`, `gateway_id`, `gateway_url`
- `workload_identity_details.workload_identity_arn`
- `tags_all`

Import by `gateway_id`.

---

## Gateway Target — `aws_bedrockagentcore_gateway_target`

Doc: https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/bedrockagentcore_gateway_target

### Required arguments
- `name` (string)
- `gateway_identifier` (string) — reference `aws_bedrockagentcore_gateway.this.gateway_id`.
- `target_configuration` (block, required) — exactly one of `mcp` or `http`:
  - `mcp {}` — exactly one of `lambda`, `mcp_server`, `api_gateway`, `open_api_schema`, `smithy_model`.
    - `lambda { lambda_arn, tool_schema { inline_payload {...} | s3 {...} } }`
    - `mcp_server { endpoint }`
    - `api_gateway { rest_api_id, stage, api_gateway_tool_configuration { tool_filter {...}, tool_override {...} } }`
  - `http { agentcore_runtime { arn (required), qualifier (default "DEFAULT") } }` — routes to a Runtime; **gateway must have no `protocol_type`.**

### Optional / credential provider
- `credential_provider_configuration` (block) — required for `lambda`/`open_api_schema`/`smithy_model`; omit for unauthenticated `mcp_server`. Exactly one of:
  - `gateway_iam_role {}` — use gateway's IAM role. For SigV4-protected upstreams (e.g. another Runtime) set `gateway_iam_role { service = "bedrock-agentcore", region = "..." }`.
  - `api_key { provider_arn (required), credential_location ("HEADER"/"QUERY_PARAMETER"), credential_parameter_name, credential_prefix }`
  - `oauth { provider_arn (required), grant_type ("CLIENT_CREDENTIALS"/"AUTHORIZATION_CODE"), default_return_url, scopes, custom_parameters }`
  - `caller_iam_credentials { service (required), region }`
  - `jwt_passthrough {}` — empty block.
- `metadata_configuration { allowed_request_headers, allowed_response_headers, allowed_query_parameters }` (max 10 each; many standard headers restricted).
- `description`, `region`.

### KMS / IAM
No direct KMS arg (inherits gateway encryption). IAM is referenced indirectly via `gateway_iam_role` (the gateway's `role_arn`) or via credential-provider ARNs.

### Computed
- `target_id` (string). Import id: `<gateway_id>,<target_id>`.

---

## Memory — `aws_bedrockagentcore_memory`

Doc: https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/bedrockagentcore_memory

### Required arguments
- `name` (string)
- `event_expiry_duration` (number) — days until memory events expire. **Must be 7–365** (the basic example's `30` is valid; `60` also valid).

### Key optional arguments
- `description` (string)
- `encryption_key_arn` (string) — **customer-managed KMS key ARN for memory encryption.** If omitted, AWS-managed encryption is used. (Note: arg name is `encryption_key_arn`, NOT `kms_key_arn`.)
- `memory_execution_role_arn` (string) — **IAM execution role** the memory service assumes; required when using custom memory strategies with model processing. Trust `bedrock-agentcore.amazonaws.com`. AWS-managed policy `AmazonBedrockAgentCoreMemoryBedrockModelInferenceExecutionRolePolicy` exists for model inference.
- `tags`, `region`.

### KMS / encryption
- `encryption_key_arn` (optional) — set to consumer CMK ARN for customer-managed encryption.

### Computed attributes (outputs)
- `arn` (string) — note: plain `arn`, not `memory_arn`.
- `id` (string) — memory ID.
- `tags_all`

### Constraints
- Only `create` and `delete` timeouts (no update) — both default 30m. Import by memory ID.

### Memory Strategy — `aws_bedrockagentcore_memory_strategy` (optional companion)
- Required: `name`, `memory_id`, `type` (`SEMANTIC|SUMMARIZATION|USER_PREFERENCE|EPISODIC|CUSTOM`), `namespaces` (set).
- `configuration {}` required only when `type = CUSTOM` (with `type` override + `consolidation`/`extraction` blocks needing `model_id` + `append_to_prompt`).
- `memory_execution_role_arn` optional (reuse the memory's role).
- Limits: max 6 strategies per memory; one of each built-in type; multiple `CUSTOM` allowed.
- Output: `memory_strategy_id`. Import `<memory_id>,<strategy_id>`.

---

## Identity primitives

### Workload Identity — `aws_bedrockagentcore_workload_identity`
Doc: https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/bedrockagentcore_workload_identity

- Required: `name` (3–255 chars; alphanumeric, `-`, `.`, `_`).
- Optional: `allowed_resource_oauth2_return_urls` (set of strings) — valid OAuth2 redirect targets.
- Computed: `workload_identity_arn`.
- No KMS arg. Import by `name`.

> Note: Runtime and Gateway each auto-create a workload identity (exposed as `workload_identity_details.workload_identity_arn`). A standalone `aws_bedrockagentcore_workload_identity` is only needed for explicitly managed/standalone identities or custom OAuth2 return URLs.

### API Key Credential Provider — `aws_bedrockagentcore_api_key_credential_provider`
Doc: https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/bedrockagentcore_api_key_credential_provider

- Required: `name` (forces replacement on change).
- Credential (choose one): `api_key` (plaintext, shows in plan/logs) **OR** write-only `api_key_wo` + `api_key_wo_version` (TF 1.11+; **recommended for production**).
- Computed: `credential_provider_arn`, `api_key_secret_arn` (Secrets Manager secret ARN), `tags_all`.
- The secret is stored in AWS Secrets Manager. Import by `name`.

### OAuth2 Credential Provider — `aws_bedrockagentcore_oauth2_credential_provider`
Doc: https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/bedrockagentcore_oauth2_credential_provider

- Required:
  - `name`
  - `credential_provider_vendor` — `CustomOauth2|GithubOauth2|GoogleOauth2|Microsoft|SalesforceOauth2|SlackOauth2`.
  - `oauth2_provider_config {}` — exactly one of `custom_oauth2_provider_config`, `github_oauth2_provider_config`, `google_oauth2_provider_config`, `microsoft_oauth2_provider_config`, `salesforce_oauth2_provider_config`, `slack_oauth2_provider_config`.
- Credentials per provider block: `client_id`+`client_secret` OR write-only `client_id_wo`+`client_secret_wo`+`client_credentials_wo_version` (TF 1.11+, recommended).
- Custom provider needs `oauth_discovery { discovery_url }` OR `oauth_discovery { authorization_server_metadata { issuer, authorization_endpoint, token_endpoint, response_types } }`.
- Computed: `credential_provider_arn`, `client_secret_arn` (Secrets Manager), `tags_all`.
- Import by `name`.

### Token Vault CMK — `aws_bedrockagentcore_token_vault_cmk` (account-level KMS for Identity)
Doc: https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/bedrockagentcore_token_vault_cmk

- Required: `kms_configuration { key_type ("CustomerManagedKey"|"ServiceManagedKey"), kms_key_arn }`.
- Optional: `token_vault_id` (defaults to `"default"`), `region`.
- This is **how customer-managed KMS is applied to the Identity/credential-provider layer** (the token vault that holds OAuth2/API-key secrets). Set `key_type = "CustomerManagedKey"` + `kms_key_arn = <consumer CMK>`.
- No additional attributes. Destroy only removes from state (does not revert the CMK). Import by `token_vault_id` (e.g. `default`).

---

## KMS / Encryption summary (where CMK plugs in)

| Primitive | CMK argument | Notes |
|---|---|---|
| Runtime | none | No direct CMK; relies on service defaults + token vault |
| Runtime endpoint | none | — |
| Gateway | `kms_key_arn` (top-level) | Encrypts gateway data |
| Gateway target | none | Inherits gateway |
| Memory | `encryption_key_arn` (top-level) | Note distinct arg name |
| Identity credential providers | none directly | Secrets in Secrets Manager; vault CMK via token vault |
| Token vault | `kms_configuration { kms_key_arn, key_type="CustomerManagedKey" }` | Account/region-wide CMK for credential token vault |

For a fully customer-managed-KMS stack the module should: set `aws_bedrockagentcore_gateway.kms_key_arn`, set `aws_bedrockagentcore_memory.encryption_key_arn`, and create one `aws_bedrockagentcore_token_vault_cmk` with `key_type = "CustomerManagedKey"`.

## IAM execution role references summary

| Primitive | IAM role argument |
|---|---|
| Runtime | `role_arn` (required) |
| Gateway | `role_arn` (required) |
| Gateway target | indirect — `credential_provider_configuration.gateway_iam_role` uses gateway role |
| Memory | `memory_execution_role_arn` (optional, required for custom strategies) |
| Credential providers / workload identity | none (no execution role) |

All execution-role trust policies use principal `bedrock-agentcore.amazonaws.com`.

## Alternatives Considered

| Alternative | Why Not |
|---|---|
| `awscc_bedrockagentcore_*` (Cloud Control) | Native `aws_*` resources exist for every needed primitive in v6.49.0, with richer schemas (write-only secret args, validation, custom claim blocks). No gap to fill. |
| Pin provider with `~>` | Module convention is `>= 6.49.0` so consumers get future fixes; these resources are new and evolving. |

## Sources

- AWS provider v6.49.0 "Bedrock AgentCore" subcategory resources (via Terraform MCP `get_provider_details`).
- https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/bedrockagentcore_agent_runtime
- https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/bedrockagentcore_agent_runtime_endpoint
- https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/bedrockagentcore_gateway
- https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/bedrockagentcore_gateway_target
- https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/bedrockagentcore_memory
- https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/bedrockagentcore_memory_strategy
- https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/bedrockagentcore_workload_identity
- https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/bedrockagentcore_api_key_credential_provider
- https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/bedrockagentcore_oauth2_credential_provider
- https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/bedrockagentcore_token_vault_cmk
- AWS docs (gateway header restrictions): https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/gateway-headers.html
