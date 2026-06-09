## Research: What existing Terraform registry modules and module-design patterns are relevant for composing an Amazon Bedrock AgentCore stack (Runtime + Gateway + Memory + Identity), and what conventions should `terraform-aws-agentcore` follow?

### Decision

Adopt the **single root module with feature-toggle (`create_*` / `enable_*`) variables and thin sub-modules** pattern proven by the community module `LuisOsuna117/agentcore/aws` (the only existing public AgentCore module), layered on the HashiCorp `terraform-aws-modules` conventions: `create_<thing>` toggles + `count`-based conditional creation, `null`-defaulted "supply existing" inputs, a flat `tags` map merged with computed names, `>=` provider pinning, and ARN/ID/URL outputs that resolve to `null` when a component is disabled.

### Resources Identified

The full AgentCore stack maps cleanly onto the `hashicorp/aws` provider's `Bedrock AgentCore` subcategory (provider v6.21+; resources present and stable as of v6.49):

- **Primary Resource**: `aws_bedrockagentcore_agent_runtime` — the containerized agent execution environment. Requires `agent_runtime_name`, `role_arn`, an `agent_runtime_artifact` block (`container_configuration.container_uri` for the consumer-provided ECR image, or `code_configuration` for S3 zip), and a `network_configuration` block (`network_mode = "PUBLIC"`).
- **Supporting Resources** (each behind a toggle):
  - `aws_bedrockagentcore_gateway` — MCP Gateway (Gateway feature). Inbound auth `AWS_IAM` (SigV4) or `CUSTOM_JWT`.
  - `aws_bedrockagentcore_gateway_target` — MCP targets attached to a gateway (one per `for_each` map entry).
  - `aws_bedrockagentcore_memory` — Memory store (Memory feature); supports `event_expiry_duration` and optional `encryption_key_arn`.
  - `aws_bedrockagentcore_memory_strategy` — optional memory strategy refinement.
  - `aws_bedrockagentcore_workload_identity` — Identity feature; note the runtime *also* exports a `workload_identity_details.workload_identity_arn` attribute, so a workload identity is implicitly created with the runtime.
  - `aws_bedrockagentcore_token_vault_cmk` — customer-managed KMS key for the Identity token vault (relevant to the customer-managed-KMS requirement on the Identity component).
  - `aws_bedrockagentcore_oauth2_credential_provider` / `aws_bedrockagentcore_api_key_credential_provider` — Identity credential providers.
  - `aws_iam_role` + `aws_iam_role_policy` — least-privilege runtime execution role (trust principal `bedrock-agentcore.amazonaws.com`; needs `ecr:GetAuthorizationToken` on `*` plus `ecr:BatchGetImage` / `ecr:GetDownloadUrlForLayer` scoped to the image repo ARN).
  - `aws_kms_key` + `aws_kms_alias` — optional module-created customer-managed key.
- **Key Arguments (runtime)**: `agent_runtime_name`, `role_arn`, `agent_runtime_artifact { container_configuration { container_uri } }`, `network_configuration { network_mode = "PUBLIC" }`, optional `protocol_configuration { server_protocol = "MCP" }`, `authorizer_configuration`, `environment_variables`, `lifecycle_configuration`.
- **Key Outputs**: `agent_runtime_arn` (`string`), `agent_runtime_id` (`string`), `agent_runtime_version` (`string`), `workload_identity_details.workload_identity_arn` (`string`); plus `gateway_arn`/`gateway_id`/`gateway_url`, `memory_arn`/`memory_id`, `execution_role_arn`, `kms_key_arn` — all resolving to `null` when the owning component is disabled.
- **Security Considerations**: customer-managed KMS on Memory (`encryption_key_arn`) and the Identity token vault (`token_vault_cmk`); `enable_key_rotation = true` on a module-created key; least-privilege execution role with image-scoped ECR permissions (avoid `bedrock:InvokeModel` on `"*"` — supply model-specific statements); ECR `IMMUTABLE` tags + `scan_on_push` for production; runtime/gateway create timeouts default to 30m.

### Rationale

**1. Composition pattern — single root module + toggles + thin sub-modules (recommended).**
The reference community module `LuisOsuna117/agentcore/aws` (v0.5.1, source `terraform-aws-agentcore`) is the canonical precedent and validates this exact design for AgentCore specifically. It uses:
- Always-on core (`create_runtime = true` default) and **optional features behind booleans defaulting to `false`**: `create_gateway`, `create_memory`, `create_build_pipeline`.
- **Thin sub-modules** for the optional primitives — its outputs reference `modules/gateway` and `modules/memory` ("creates an AgentCore Gateway resource using `modules/gateway`"). The root module wires sub-modules and re-exports their outputs.
- A reserved-key composition pattern for cross-component wiring (`gateway_attach_runtime_target` attaches the module-created runtime as a gateway target using the stable key `"runtime"`), demonstrating how to safely compose Runtime+Gateway in one call.

This matches HashiCorp guidance and the dominant `terraform-aws-modules` idiom. Recommendation for `terraform-aws-agentcore`:
- **Runtime is always-on** (the reason the module exists). Gateway / Memory / Identity are **optional, default-off** via `create_gateway` / `create_memory` / `create_identity` (or `enable_*` — pick one verb and use it consistently; `create_*` is the `terraform-aws-modules` convention and pairs naturally with create-vs-supply toggles).
- Use **`count = var.create_x ? 1 : 0`** for the singleton optional components (Gateway, Memory, KMS key, IAM role). Use **`for_each`** for collections (gateway targets, memory strategies) per the style guide's "prefer for_each for iteration, count for conditional creation" rule.
- Keep sub-modules **thin and internal** (`modules/gateway`, `modules/memory`, `modules/identity`) only if a component has enough internal resources/wiring to justify it; otherwise a flat root with grouped files is simpler. The reference module submodules Gateway and Memory but keeps Runtime + IAM + ECR flat — a reasonable split to mirror.

**2. Create-vs-supply toggle (KMS key and IAM role).**
Both the AgentCore reference and the canonical `terraform-aws-modules/kms/aws` (120M+ downloads) establish the idiom:
- A boolean `create_<thing>` (e.g. `create_execution_role` default `true`, `create_kms_key`).
- A paired `null`-defaulted "supply existing" input (`execution_role_arn`, `kms_key_arn` / `gateway_kms_key_arn` / `memory_encryption_key_arn`).
- An output that returns the created ARN **or** the supplied ARN transparently: the reference module documents `execution_role_arn` as "Will equal `var.execution_role_arn` when `create_execution_role = false`". Implement as `output ... value = var.create_execution_role ? aws_iam_role.this[0].arn : var.execution_role_arn`.
- `terraform-aws-modules/kms` adds a top-level `create` bool ("affects all resources") and `enable_key_rotation = true` default — adopt `enable_key_rotation = true` as the secure default for any module-created key.

**3. Conventions confirmed across both references:**
- **Naming**: required `name` input used as a base/prefix for all resources (reference: "Base name used as a prefix... Must start with a letter, max 32 characters"); per-resource overrides default to `var.name` when `null` (`runtime_name`, `gateway_name`, `memory_name`, `ecr_repository_name`). Note AgentCore API quirk: runtime names disallow hyphens — the reference auto-converts hyphens to underscores. Support both `name` and (where AWS allows) `name_prefix` semantics via a `*_use_name_prefix` style bool only if needed.
- **Tagging**: single flat `tags` map (`map(string)`, default `{}`) "merged with module-level defaults" — implement `local.tags = merge(local.module_tags, var.tags)` and apply to every taggable resource.
- **Validation**: validate `network_mode ∈ {PUBLIC, VPC}`, `server_protocol ∈ {HTTP, MCP, A2A}`, `gateway_authorizer_type ∈ {AWS_IAM, CUSTOM_JWT}`, `memory_event_expiry_duration ∈ [7,365]`, mutually-exclusive `image_uri` xor build pipeline, and "exactly one of endpoint/agent_runtime_arn" on gateway targets. Use cross-variable validation (or `precondition`) for the create-vs-supply pairs (e.g. `create_execution_role = false` requires non-null `execution_role_arn`).
- **Secure defaults**: KMS-managed encryption falls back to AWS-managed when key ARN is `null`, but the design here mandates customer-managed KMS — make the key ARN inputs first-class and validate non-null when the component is enabled; `ecr_scan_on_push = true`, force-destroy/force-delete default `false`.
- **Outputs**: expose ARNs, IDs, and endpoint URLs (`*_arn`, `*_id`, `gateway_url`, `agent_runtime_version`, `effective_image_uri`); every optional-component output documents "Null when `create_x = false`". Provide a backwards-compat alias only when renaming (reference keeps `container_image_uri` as an alias for `effective_image_uri`).
- **Provider pinning**: modules use **`>=`** not `~>` (style guide + tf-architecture-patterns). AgentCore resources require **`hashicorp/aws >= 6.21`** (reference module's floor); the `aws_bedrockagentcore_token_vault_cmk` and full resource set are present through v6.49. Pin `required_version >= 1.8` (reference example requirement) to get `import` blocks and stable `optional()` object defaults. Note the reference module is OpenTofu-tested (`tofu`) but Terraform-compatible.

### Alternatives Considered

| Alternative | Why Not |
| ----------- | -------- |
| Always-on components (no toggles) | Forces Gateway/Memory/Identity on every consumer, breaking least-cost/least-privilege minimal deployments; contradicts the reference module's default-`false` optionals. |
| Separate top-level modules per component (consumer composes them) | More flexible but pushes cross-component wiring (runtime ARN -> gateway target, shared KMS/IAM) onto the consumer; the single-call `gateway_attach_runtime_target` pattern shows in-module composition is cleaner for the "full stack" use case. |
| `for_each` for the singleton optional components | `count = var.create_x ? 1 : 0` is the idiomatic conditional-creation form (style guide); `for_each` is reserved for true collections (targets, strategies, aliases). |
| `~>` provider constraint | tf-architecture-patterns and the style guide both mandate `>=` for modules to maximize consumer compatibility; `~> 6.0` (as `Flaconi/bedrock-agent` uses) over-constrains. |
| One supply input shared for "create or supply" without a boolean | Ambiguous (is `null` "create default" or "error"?); the explicit `create_* + *_arn` pair (KMS module, AgentCore module) is unambiguous and self-documenting. |

### Sources

- Public module (primary precedent): `LuisOsuna117/agentcore/aws` v0.5.1 — https://github.com/LuisOsuna117/terraform-aws-agentcore (composable `create_runtime`/`create_gateway`/`create_memory` toggles, `modules/gateway`+`modules/memory` submodules, create-vs-supply IAM role, `name`-prefix naming, flat `tags`, null-when-disabled outputs, `aws >= 6.21`).
- Canonical toggle/KMS reference: `terraform-aws-modules/kms/aws` v4.2.0 — https://github.com/terraform-aws-modules/terraform-aws-kms (`create` bool, `enable_key_rotation = true` default, `key_arn`/`key_id` outputs, `aws >= 6.28`).
- Comparison module: `Flaconi/bedrock-agent/aws` v1.2.1 — https://github.com/Flaconi/terraform-aws-bedrock-agent (`additional_agent_policy_statements` extensibility pattern, aggregated object outputs, `~> 6.0` — an over-constraint to avoid).
- Provider docs: `aws_bedrockagentcore_agent_runtime` (providerDocID 12464888) and the `Bedrock AgentCore` resource family — `_gateway`, `_gateway_target`, `_memory`, `_memory_strategy`, `_workload_identity`, `_token_vault_cmk`, `_oauth2_credential_provider` — hashicorp/aws v6.49.0.
