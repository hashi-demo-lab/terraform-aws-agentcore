## Research: Edge cases, resource dependencies/ordering, and failure modes provisioning an Amazon Bedrock AgentCore stack (Runtime + Gateway + Memory + Identity) with Terraform

### Decision

Build `terraform-aws-agentcore` around the `aws_bedrockagentcore_*` resource family (provider `hashicorp/aws` >= 6.49.0), wiring Runtime -> Runtime Endpoint, Gateway -> Gateway Target, Memory -> Memory Strategy, and Workload/Token-Vault Identity with explicit ordering. IAM roles + customer-managed KMS keys (with correct key policies) must be fully provisioned before the AgentCore resources, and several non-obvious gotchas (IAM eventual consistency, KMS key-policy grants to the service principal, target authorizer wiring, CUSTOM-strategy `memory_execution_role_arn`, region availability) must be designed for explicitly.

---

### Resources Identified (full stack)

- **Primary**: `aws_bedrockagentcore_agent_runtime` — containerized agent execution environment.
- **Supporting**:
  - `aws_bedrockagentcore_agent_runtime_endpoint` — network-accessible endpoint bound to a runtime version.
  - `aws_bedrockagentcore_gateway` — converts APIs/Lambda/HTTP services into MCP tools.
  - `aws_bedrockagentcore_gateway_target` — the concrete target (Lambda / OpenAPI / Smithy / MCP server / API Gateway / HTTP-to-runtime) behind a gateway.
  - `aws_bedrockagentcore_memory` — persistent conversation/session memory store.
  - `aws_bedrockagentcore_memory_strategy` — per-memory processing strategy (SEMANTIC / SUMMARIZATION / USER_PREFERENCE / EPISODIC / CUSTOM).
  - `aws_bedrockagentcore_workload_identity` — OAuth2 workload identity (also created implicitly and surfaced via `workload_identity_details` on Runtime and Gateway).
  - `aws_bedrockagentcore_token_vault_cmk` — sets the CMK for the (account-singleton) token vault used by Identity credential providers.
  - `aws_bedrockagentcore_api_key_credential_provider` / `aws_bedrockagentcore_oauth2_credential_provider` — outbound credentials for gateway targets; both materialize a Secrets Manager secret (`*_secret_arn`).
  - Companion AWS resources: `aws_iam_role` + `aws_iam_role_policy`, `aws_kms_key` + `aws_kms_key_policy`, consumer-provided ECR image (read-only), optional `aws_lambda_function` for Lambda targets.

---

### 1. Resource dependency ordering and eventual-consistency gotchas

**Hard (attribute-derived) dependencies — Terraform infers these automatically when wired by reference:**

- Runtime Endpoint -> Runtime: `agent_runtime_id = aws_bedrockagentcore_agent_runtime.this.agent_runtime_id`. Import ID is the composite `agent_runtime_id,name`.
- Gateway Target -> Gateway: `gateway_identifier = aws_bedrockagentcore_gateway.this.gateway_id`. Import ID is `gateway_id,target_id`.
- Memory Strategy -> Memory: `memory_id = aws_bedrockagentcore_memory.this.id`. `memory_id` and `type` are **ForceNew** (changing either recreates the strategy). Import ID is `memory_id,strategy_id`.
- HTTP gateway target -> Runtime: `target_configuration.http.agentcore_runtime.arn = ...agent_runtime_arn`, creating a Gateway -> Runtime edge that crosses the two sub-stacks. Plan this so the runtime is fully created (endpoint optional) before the HTTP target.

**Soft dependencies that need explicit `depends_on` (no attribute reference exists):**

- **IAM role policy attachment must settle before the AgentCore resource that assumes the role.** The runtime/gateway/memory resources only reference `role_arn`; they do NOT reference the inline `aws_iam_role_policy`/`aws_iam_role_policy_attachment`. Without `depends_on = [aws_iam_role_policy.x]` Terraform may create the runtime before the ECR-pull permissions exist, and the service's CreateAgentRuntime validation (which pulls/inspects the image) can fail. Add `depends_on` from each AgentCore resource to its role's policy/attachment.
- **IAM eventual consistency / propagation.** Newly created roles and freshly attached policies are not instantly visible to the `bedrock-agentcore.amazonaws.com` service principal. A create can intermittently fail with AccessDenied even when HCL is correct. Mitigations: keep the `depends_on` edges above; rely on the resource's 30m create timeout for retry; if flakiness persists, a short `time_sleep` between role-policy and the AgentCore resource is the standard escape hatch. Surface this in the test plan as a known intermittent.
- **Token vault CMK before credential providers.** `aws_bedrockagentcore_token_vault_cmk` configures the account-level token vault encryption; credential providers (`api_key`/`oauth2`) write their secrets into that vault. Order the CMK resource before the credential providers so their Secrets Manager secrets are encrypted with the CMK from creation, not re-encrypted later.

**Lifecycle / replacement edges:**

- Runtime endpoints pin an `agent_runtime_version` (optional). Pushing a new image updates the runtime and bumps `agent_runtime_version`; an endpoint pinned to an old version will not pick up the new image. If the module exposes version pinning, document that endpoint and runtime updates are decoupled.
- `aws_bedrockagentcore_memory` exposes only `create`/`delete` timeouts (no `update`) — most meaningful changes are replacements. `memory_strategy` ForceNew on `memory_id`/`type`/`configuration.type` means strategy changes cascade to recreation; sequence with `create_before_destroy` only where the service allows duplicate transient strategies (it generally does not — see limits below).

---

### 2. KMS customer-managed key policy requirements (classic gotcha)

The module is customer-managed-KMS. Two distinct KMS attach points exist and each needs the service principal authorized in the **key policy** (grants alone are insufficient for some operations, and key policy is what the provider/AWS validates):

- **Runtime / Gateway / Memory encryption**:
  - Memory: `encryption_key_arn`. Gateway: `kms_key_arn`. (Runtime encrypts via the service; data-plane artifacts/session storage use the key indirectly.)
- **Token vault CMK**: `aws_bedrockagentcore_token_vault_cmk.kms_configuration.kms_key_arn` with `key_type = "CustomerManagedKey"`.

**Key policy must grant the AgentCore service principal `kms:Encrypt`, `kms:Decrypt`, `kms:GenerateDataKey*`, `kms:DescribeKey`, and `kms:CreateGrant` (CreateGrant is the one most often forgotten — the service creates grants on the CMK to operate asynchronously on your behalf).** Scope with `kms:ViaService = "bedrock-agentcore.<region>.amazonaws.com"` and `kms:CallerAccount` conditions, plus the `kms:GrantIsForAWSResource = true` condition on the CreateGrant statement for least privilege. The execution IAM role (not just the service principal) also needs `kms:Decrypt`/`kms:DescribeKey` when it reads encrypted memory/secrets.

**Failure modes to test:** key policy missing `kms:CreateGrant` -> async memory/identity operations fail after a seemingly successful create; key policy missing the service principal entirely -> CreateMemory/CreateGateway returns AccessDenied; `ViaService` set to the wrong region -> silent denial. Because `aws_kms_key_policy` is a separate resource from the AgentCore resources with no attribute reference, add `depends_on` so the policy is in place before the AgentCore resource is created. Note `aws_bedrockagentcore_token_vault_cmk` deletion does NOT revert the CMK (it only drops from state) — destroy/recreate leaves the vault pointing at the old key; flag as drift.

---

### 3. Gateway target authorizer / credential-provider edge cases

**Inbound auth (on the Gateway itself):** `authorizer_type` is `CUSTOM_JWT` or `AWS_IAM`. When `CUSTOM_JWT`, the `authorizer_configuration.custom_jwt_authorizer` block is **required** and `discovery_url` must end with `.well-known/openid-configuration` (provider-validated). `protocol_type` is `MCP` or **omitted** — omitting it is what enables HTTP-to-runtime targets; you cannot mix an MCP `protocol_type` gateway with an HTTP target (provider note: HTTP targets only attach to gateways with no `protocol_type`). This is a hard either/or the module interface must encode.

**Outbound credential wiring (on the Target) — `credential_provider_configuration` accepts exactly one of:**

- `gateway_iam_role {}` — empty for plain IAM-role auth; but for SigV4-protected upstreams (e.g. another AgentCore Runtime) you MUST set `service = "bedrock-agentcore"` (optionally `region`). Empty block against a SigV4 endpoint fails to sign.
- `api_key` / `oauth` — `provider_arn` points at a credential-provider/OIDC ARN; OAuth `AUTHORIZATION_CODE` grant **requires** `default_return_url`, and that URL must also appear in the Workload Identity's `allowed_resource_oauth2_return_urls`. Mismatch between the two is a common silent OAuth failure.
- `caller_iam_credentials` (requires `service`), `jwt_passthrough` (empty).
- **`credential_provider_configuration` is required for `lambda`, `open_api_schema`, and `smithy_model` targets, but must be omitted for an unauthenticated `mcp_server` target.** Supplying it on a no-auth mcp_server (or omitting it on a Lambda target) is a validation error.

**Target-type edge cases:**

- `mcp.lambda` requires a `tool_schema` (`inline_payload` with full input/output schema, or `s3`). Deeply nested schemas hit HCL block limits — use `items_json` / `properties_json` (mutually exclusive) escape hatches.
- `api_gateway` target requires `rest_api_id` + `stage` + `tool_filter`/`tool_override`; `filter_path`/`path` must match existing REST API paths or creation fails.
- `metadata_configuration` header/query propagation: max 10 each; header names alphanumeric+hyphen+underscore only; many standard headers are restricted and `X-Amzn-*` is prohibited except `X-Amzn-Bedrock-AgentCore-Runtime-Custom-*`. Validation is enforced server-side.

---

### 4. Memory strategy / retention edge cases

- `event_expiry_duration` is **required** and must be 7–365 (days). Values outside the range fail validation — test 6 and 366 as negatives.
- **Per-memory strategy limits (enforced by AWS, not the provider):** max **6** strategies total per memory; only **one** of each built-in type (`SEMANTIC`, `SUMMARIZATION`, `USER_PREFERENCE`, `EPISODIC`); multiple `CUSTOM` allowed within the 6 cap. A `for_each` over user-supplied strategies must guard these or apply fails mid-way (partial state).
- `configuration` block is **required when `type = CUSTOM` and must be omitted otherwise**. `configuration.type` (`*_OVERRIDE`) is ForceNew. `extraction` cannot be combined with `SUMMARY_OVERRIDE`. `consolidation`/`extraction` blocks, once added, cannot be removed without recreate.
- CUSTOM strategies (and any model-processing strategy) require `memory_execution_role_arn` on the memory (or threaded to the strategy) with Bedrock model-invocation permissions — AWS provides `AmazonBedrockAgentCoreMemoryBedrockModelInferenceExecutionRolePolicy`. Missing role -> CUSTOM strategy create fails. The referenced `model_id`s (e.g. `anthropic.claude-3-sonnet-*`) must be enabled/available in the region.
- Namespace templates use placeholders like `{sessionId}`, `{actorId}`, `{memoryStrategyId}` — malformed templates are accepted at apply but break at runtime; validate format in the module.

---

### 5. Service quotas, regional availability, import IDs, drift

- **Regional availability:** Bedrock AgentCore is GA only in a subset of regions (notably us-east-1, us-west-2, plus a limited set of others). The full stack (Gateway, Memory long-term strategies, Identity/token vault) may lag the core Runtime in some regions. Module should not hardcode region; document the availability gap and that the foundation models referenced by memory strategies must also be enabled in that region. Test plan should target us-east-1/us-west-2.
- **Quotas:** soft account limits exist on number of agent runtimes, gateways, gateway targets per gateway, and memories; the 6-strategies-per-memory limit is hard. CreateAgentRuntime/CreateGateway are long-running (hence 30m default create timeouts). Concurrent creates of many resources can throttle — keep `-parallelism` modest in CI.
- **Import ID formats (verified from provider docs):**
  - Runtime: `agent-runtime-id` (e.g. `AGENTRUNTIME1234567890`).
  - Runtime Endpoint: `agent_runtime_id,name`.
  - Gateway: `gateway_id`.
  - Gateway Target: `gateway_id,target_id`.
  - Memory: `memory_id`.
  - Memory Strategy: `memory_id,strategy_id`.
  - Workload Identity: `name`.
  - Token Vault CMK: `default` (the token vault id; account-singleton).
  - API Key / OAuth2 credential provider: provider `name`.
- **Drift behaviors:**
  - `token_vault_cmk` delete only removes from state, never reverts the CMK — destroy leaves real config unchanged (drift on re-import).
  - `memory_strategy_id` maps to the API/CloudFormation `strategyId` — naming mismatch to watch when correlating console/state.
  - Secrets created by credential providers live in Secrets Manager (`*_secret_arn`); rotating the secret outside Terraform causes no plan diff (the value isn't read back) — use `*_wo_version` increment to force updates.

---

### 6. Negative / validation scenarios worth testing

| Scenario | Expected failure |
| -------- | ---------------- |
| Invalid/garbage `container_uri` or unreachable ECR image | CreateAgentRuntime fails image inspection (after IAM settles) |
| Both `code_configuration` and `container_configuration` set (or neither) | "exactly one of" validation error |
| Execution role missing `ecr:GetAuthorizationToken` / `BatchGetImage` | runtime create AccessDenied |
| KMS key policy missing `kms:CreateGrant` for service principal | create succeeds but async memory/identity ops fail |
| KMS key policy omits service principal | CreateMemory/CreateGateway AccessDenied |
| `network_mode = VPC` without `network_mode_config` subnets/SGs | conflicting/incomplete network config error |
| `discovery_url` not ending in `.well-known/openid-configuration` | provider validation error |
| Gateway with `protocol_type = MCP` + HTTP target | rejected (HTTP targets require no protocol_type) |
| `mcp_server` target WITH `credential_provider_configuration` (no-auth case) | validation error |
| Lambda/OpenAPI/Smithy target WITHOUT `credential_provider_configuration` | validation error |
| OAuth `AUTHORIZATION_CODE` without `default_return_url` (or URL not in workload identity allowlist) | create error / runtime OAuth failure |
| `event_expiry_duration` = 6 or 366 | out-of-range (7–365) validation error |
| 7th strategy on a memory, or 2nd `SEMANTIC` strategy | quota/uniqueness error, partial apply |
| `configuration` block present on non-CUSTOM strategy (or absent on CUSTOM) | conditional-requirement error |
| `extraction` block under `SUMMARY_OVERRIDE` | rejected |
| Name length/charset: Workload Identity must be 3–255 chars, alphanumeric + `-._`; similar constraints on runtime/gateway/memory names | name validation error |
| `metadata_configuration` >10 headers, restricted/`X-Amzn-*` header, or invalid char | schema validation error |
| Plaintext `api_key`/`client_secret` instead of `*_wo` | works but leaks secret into plan/state (test should assert `_wo` path) |

---

### Rationale

All resource shapes, required/ForceNew arguments, conditional "exactly one of" constraints, import ID formats, and timeout defaults are taken directly from the `hashicorp/aws` v6.49.0 provider documentation for the `aws_bedrockagentcore_*` resources (retrieved via Terraform MCP). The KMS-CreateGrant and IAM-propagation gotchas are standard AWS service-integration behaviors that the provider docs imply (separate KMS/IAM resources with no attribute linkage to the AgentCore resources) and that the module must bridge with `depends_on`. The strategy limits, `event_expiry_duration` range, header restrictions, and authorizer either/or rules are explicitly called out in the provider docs' notes.

### Alternatives Considered

| Alternative | Why not |
| ----------- | ------- |
| Rely on implicit ordering only (no `depends_on` to IAM/KMS policies) | AgentCore resources reference only `role_arn`/`*_key_arn`, not the policy resources — Terraform won't order policy-before-create, causing intermittent AccessDenied |
| Use KMS grants only (skip key policy) | Some operations validate against the key policy; service needs `kms:CreateGrant` granted in the policy itself — grants alone don't bootstrap |
| `ServiceManagedKey` token vault | Violates the customer-managed-KMS requirement; loses key rotation/audit control |
| Pin endpoints to runtime version by default | Decouples image updates from endpoints, surprising consumers; expose as opt-in instead |

### Sources

- Provider docs (hashicorp/aws v6.49.0, via Terraform MCP): `aws_bedrockagentcore_agent_runtime`, `_agent_runtime_endpoint`, `_gateway`, `_gateway_target`, `_memory`, `_memory_strategy`, `_workload_identity`, `_token_vault_cmk`, `_api_key_credential_provider`, `_oauth2_credential_provider`.
- AWS docs referenced by provider notes: https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/gateway-headers.html (restricted header list).
- Managed policy cited in provider example: `AmazonBedrockAgentCoreMemoryBedrockModelInferenceExecutionRolePolicy`.
- Service principal: `bedrock-agentcore.amazonaws.com`; KMS ViaService: `bedrock-agentcore.<region>.amazonaws.com`.
