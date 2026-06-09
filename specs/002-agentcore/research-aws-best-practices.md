## Research: AWS recommended architecture and security best practices for Amazon Bedrock AgentCore (Runtime, Gateway, Memory, Identity)

### Decision

Build `terraform-aws-agentcore` with OPINIONATED SECURE defaults: a per-component least-privilege IAM execution role trusting `bedrock-agentcore.amazonaws.com` (scoped by `aws:SourceAccount` / `aws:SourceArn` confused-deputy guards), a customer-managed KMS key wired into Runtime/Memory/Gateway plus the Identity token vault CMK, CloudWatch logging + OpenTelemetry/X-Ray observability enabled, and `PUBLIC` (AWS-managed) network mode — every default overridable (BYO role/KMS, `VPC` network mode, AWS-managed encryption, observability off).

### Resources Identified

- **Primary Resources**:
  - `aws_bedrockagentcore_agent_runtime` — containerized agent execution environment (ECR image or S3 code zip)
  - `aws_bedrockagentcore_gateway` + `aws_bedrockagentcore_gateway_target` — turns APIs/Lambda/runtimes into MCP tools
  - `aws_bedrockagentcore_memory` (+ `aws_bedrockagentcore_memory_strategy`) — persistent cross-session agent memory
  - `aws_bedrockagentcore_workload_identity` — OAuth2 workload identity for the agent
- **Supporting Resources**:
  - `aws_iam_role` + `aws_iam_role_policy` (or `aws_iam_policy` + attachment) — execution role(s), trust policy `bedrock-agentcore.amazonaws.com`
  - `aws_kms_key` + `aws_kms_alias` + `aws_kms_key_policy` — customer-managed CMK for encryption at rest
  - `aws_bedrockagentcore_token_vault_cmk` — sets the Identity token-vault CMK to `CustomerManagedKey`
  - `aws_bedrockagentcore_oauth2_credential_provider` / `aws_bedrockagentcore_api_key_credential_provider` — outbound creds (backed by Secrets Manager)
  - `aws_bedrockagentcore_agent_runtime_endpoint` — named/versioned invoke endpoints
  - `aws_cloudwatch_log_group` — explicit, encrypted, retention-bounded log groups for observability
  - `aws_ecr_repository` (referenced, usually BYO) — image source for container runtimes
- **Key Arguments**:
  - Runtime: `role_arn` (required), `network_configuration.network_mode` = `PUBLIC|VPC`, `agent_runtime_artifact.container_configuration.container_uri` or `code_configuration`, `protocol_configuration.server_protocol` = `HTTP|MCP|A2A`, `authorizer_configuration.custom_jwt_authorizer`, `environment_variables`.
  - Memory: `encryption_key_arn` (KMS), `memory_execution_role_arn`, `event_expiry_duration` (7–365 days, required).
  - Gateway: `authorizer_type` = `CUSTOM_JWT|AWS_IAM`, `kms_key_arn`, `protocol_type = MCP`, `protocol_configuration.mcp`, `interceptor_configuration`.
  - Identity token vault: `kms_configuration.key_type = CustomerManagedKey` + `kms_key_arn`.
- **Key Outputs**:
  - Runtime: `agent_runtime_arn` (`string`), `agent_runtime_id` (`string`), `agent_runtime_version` (`string`), `workload_identity_details.workload_identity_arn` (`string`)
  - Gateway: `gateway_arn`, `gateway_id`, `gateway_url`, `workload_identity_details.workload_identity_arn`
  - Memory: `arn`, `id`
  - Credential providers: `credential_provider_arn`, `*_secret_arn` (Secrets Manager ARN)
- **Security Considerations**: least-privilege execution role with confused-deputy guards; customer-managed KMS everywhere (Runtime/Memory/Gateway/token vault); CloudWatch Logs + OTEL/X-Ray; JWT or SigV4 inbound auth (never anonymous); credential secrets via Secrets Manager and Terraform write-only args; bounded Memory retention; HTTP header allowlisting on Gateway targets.

---

### IAM Execution Role — trust policy and least-privilege permissions

**Service principal (validated in provider examples for runtime, memory, gateway, gateway_target):** `bedrock-agentcore.amazonaws.com`.

**Trust policy (with confused-deputy guards — recommended over the bare provider example):**

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AssumeRoleFromAgentCore",
      "Effect": "Allow",
      "Principal": { "Service": "bedrock-agentcore.amazonaws.com" },
      "Action": "sts:AssumeRole",
      "Condition": {
        "StringEquals": { "aws:SourceAccount": "<ACCOUNT_ID>" },
        "ArnLike": {
          "aws:SourceArn": "arn:aws:bedrock-agentcore:<REGION>:<ACCOUNT_ID>:*"
        }
      }
    }
  ]
}
```

**Least-privilege starting permissions policy for an AgentCore Runtime (container image source):**

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ECRAuthToken",
      "Effect": "Allow",
      "Action": "ecr:GetAuthorizationToken",
      "Resource": "*"
    },
    {
      "Sid": "ECRImagePull",
      "Effect": "Allow",
      "Action": [
        "ecr:BatchGetImage",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchCheckLayerAvailability"
      ],
      "Resource": "arn:aws:ecr:<REGION>:<ACCOUNT_ID>:repository/<REPO_NAME>"
    },
    {
      "Sid": "CloudWatchLogs",
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogStreams"
      ],
      "Resource": "arn:aws:logs:<REGION>:<ACCOUNT_ID>:log-group:/aws/bedrock-agentcore/runtimes/*"
    },
    {
      "Sid": "CloudWatchLogsCreateGroup",
      "Effect": "Allow",
      "Action": "logs:CreateLogGroup",
      "Resource": "arn:aws:logs:<REGION>:<ACCOUNT_ID>:log-group:/aws/bedrock-agentcore/runtimes/*"
    },
    {
      "Sid": "CloudWatchMetrics",
      "Effect": "Allow",
      "Action": "cloudwatch:PutMetricData",
      "Resource": "*",
      "Condition": {
        "StringEquals": { "cloudwatch:namespace": "bedrock-agentcore" }
      }
    },
    {
      "Sid": "XRayTracing",
      "Effect": "Allow",
      "Action": [
        "xray:PutTraceSegments",
        "xray:PutTelemetryRecords",
        "xray:GetSamplingRules",
        "xray:GetSamplingTargets"
      ],
      "Resource": "*"
    },
    {
      "Sid": "BedrockModelInvoke",
      "Effect": "Allow",
      "Action": ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"],
      "Resource": "arn:aws:bedrock:<REGION>::foundation-model/*"
    },
    {
      "Sid": "WorkloadIdentityAndTokens",
      "Effect": "Allow",
      "Action": [
        "bedrock-agentcore:GetWorkloadAccessToken",
        "bedrock-agentcore:GetWorkloadAccessTokenForJWT",
        "bedrock-agentcore:GetWorkloadAccessTokenForUserId",
        "bedrock-agentcore:GetResourceOauth2Token",
        "bedrock-agentcore:GetResourceApiKey"
      ],
      "Resource": [
        "arn:aws:bedrock-agentcore:<REGION>:<ACCOUNT_ID>:workload-identity-directory/default",
        "arn:aws:bedrock-agentcore:<REGION>:<ACCOUNT_ID>:workload-identity-directory/default/workload-identity/<AGENT_NAME>-*",
        "arn:aws:bedrock-agentcore:<REGION>:<ACCOUNT_ID>:token-vault/default/*"
      ]
    },
    {
      "Sid": "KMSForEncryptedResources",
      "Effect": "Allow",
      "Action": ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"],
      "Resource": "arn:aws:kms:<REGION>:<ACCOUNT_ID>:key/<KEY_ID>",
      "Condition": {
        "StringEquals": {
          "kms:ViaService": "bedrock-agentcore.<REGION>.amazonaws.com"
        }
      }
    }
  ]
}
```

Notes:
- `ecr:GetAuthorizationToken` requires `Resource: "*"` (it does not support resource scoping) — isolate it in its own statement. The actual layer/image pulls are scoped to the repo ARN.
- For **S3 code-zip** runtimes, drop the ECR statements and add `s3:GetObject` (+ `s3:GetObjectVersion`) scoped to the code object, plus `kms:Decrypt` if the bucket is SSE-KMS.
- For Memory with model-backed strategies, AWS publishes a managed policy: **`AmazonBedrockAgentCoreMemoryBedrockModelInferenceExecutionRolePolicy`** (validated in the `aws_bedrockagentcore_memory` provider example). The module should let consumers attach this managed policy as the secure default for `memory_execution_role_arn`, and offer an inline least-privilege override.
- Gateway execution role needs `lambda:InvokeFunction` (scoped to target Lambda ARNs) for Lambda targets, `bedrock-agentcore:*` SigV4 invoke for `mcp_server`/`agentcore_runtime` HTTP targets, and `secretsmanager:GetSecretValue` (scoped to the credential-provider secret ARNs) for API-key/OAuth targets.
- Memory/Gateway/Runtime should each get their **own** role rather than sharing one — keeps blast radius per component.

---

### KMS encryption at rest across components

| Component | KMS wiring | Terraform argument | Default if omitted |
|-----------|-----------|--------------------|--------------------|
| Memory | Encrypts stored events/strategies | `aws_bedrockagentcore_memory.encryption_key_arn` | AWS-managed encryption |
| Gateway | Encrypts gateway data | `aws_bedrockagentcore_gateway.kms_key_arn` | AWS-managed encryption |
| Identity token vault | Encrypts OAuth/API-key tokens & secrets references | `aws_bedrockagentcore_token_vault_cmk.kms_configuration { key_type = "CustomerManagedKey", kms_key_arn = ... }` | `ServiceManagedKey` |
| Runtime | Session storage / filesystem encryption inherited from mounted S3/EFS + Bedrock model data | (no direct `kms_key_arn` arg on runtime; secure mounted filesystems and downstream resources) | AWS-managed |
| Credential providers | Client secrets / API keys land in **AWS Secrets Manager**; the secret is encrypted by the token-vault CMK / Secrets Manager KMS | `*_secret_arn` outputs reference the SM secret | AWS-managed Secrets Manager key |

**Opinionated default:** create one customer-managed CMK (or accept a BYO `kms_key_arn`) and wire it to Memory, Gateway, and the token vault CMK. The CMK key policy must grant the AgentCore service principal usage:

```json
{
  "Sid": "AllowAgentCoreUseOfTheKey",
  "Effect": "Allow",
  "Principal": { "Service": "bedrock-agentcore.amazonaws.com" },
  "Action": ["kms:Decrypt", "kms:GenerateDataKey*", "kms:DescribeKey", "kms:CreateGrant"],
  "Resource": "*",
  "Condition": { "StringEquals": { "aws:SourceAccount": "<ACCOUNT_ID>" } }
}
```

`kms:CreateGrant` is required because AgentCore creates grants for asynchronous/background processing (e.g. Memory strategy model inference). Enable key rotation (`enable_key_rotation = true`) on the module-created CMK.

The `aws_bedrockagentcore_token_vault_cmk` resource note warns deletion only removes it from state (does not revert the CMK), so document that the token vault remains on the CMK after `destroy`.

---

### Observability — what the module should wire up

AgentCore is natively integrated with **CloudWatch (GenAI Observability)** and emits **OpenTelemetry (OTEL)** traces that surface in **CloudWatch / X-Ray (Transaction Search)**.

- **Log groups**: AgentCore writes to CloudWatch Logs under `/aws/bedrock-agentcore/runtimes/<runtime-id>-<endpoint>` (and equivalents for gateway/memory). The module should pre-create `aws_cloudwatch_log_group` resources with:
  - `retention_in_days` (opinionated default, e.g. 90; overridable; default-on rather than never-expire)
  - `kms_key_id` set to the module CMK (CloudWatch Logs CMK encryption)
- **Metrics**: AgentCore publishes metrics to the `bedrock-agentcore` CloudWatch namespace (invocations, latency, errors, token usage, session counts). Scope `cloudwatch:PutMetricData` in the role to that namespace (see policy above). Module can optionally provision `aws_cloudwatch_metric_alarm`s (error rate, throttle).
- **Tracing (OTEL / X-Ray)**: enable OTEL instrumentation by setting the runtime `code_configuration.entry_point` to `["opentelemetry-instrument", "main.py"]` (provider doc example) for code runtimes, or baking the ADOT/OTEL instrumentation into the container image. Grant `xray:PutTraceSegments`/`PutTelemetryRecords` + sampling. AWS requires **CloudWatch Transaction Search** to be enabled (one-time account/region setup) to view spans — note this is an account-level prerequisite the module can flag but typically should not silently toggle.
- **Module wiring (opinionated, on by default, overridable via `enable_observability`)**:
  1. Create CMK-encrypted, retention-bounded log groups.
  2. Add the Logs/Metrics/X-Ray statements to the execution role.
  3. Default container/code runtimes to OTEL-instrumented entry points.
  4. Optional `aws_cloudwatch_dashboard` / alarms behind a sub-flag.

---

### Gateway security (inbound/outbound auth, MCP)

- **Inbound auth (required, no anonymous)**: `authorizer_type` is `CUSTOM_JWT` (OIDC/JWT bearer; `discovery_url` must end `.well-known/openid-configuration`, plus `allowed_audience`/`allowed_clients`/`allowed_scopes` and `custom_claim` matching) or `AWS_IAM` (SigV4). Opinionated default: require one to be set; do not expose an unauthenticated gateway. Tighten with `allowed_audience` + `allowed_clients` rather than leaving them empty.
- **Outbound / target auth** (`credential_provider_configuration`, exactly one): `gateway_iam_role` (use `service = "bedrock-agentcore"` for SigV4 to another runtime / `mcp_server`), `api_key`, `oauth` (`CLIENT_CREDENTIALS` for M2M, `AUTHORIZATION_CODE` for user-delegated), `caller_iam_credentials`, or `jwt_passthrough`. Prefer `gateway_iam_role` (no stored secret) > OAuth client-credentials > API key.
- **MCP protocol**: `protocol_type = MCP` with `protocol_configuration.mcp` controlling `instructions`, `search_type` (`SEMANTIC`), `session_configuration.session_timeout_in_seconds` (900–28800), `streaming_configuration`, and `supported_versions`. Bound session timeouts; pin `supported_versions`.
- **Header / query propagation hardening**: `metadata_configuration` limits propagated headers/query params (max 10 each). A large set of auth/security/CORS headers is **blocked by schema validation**, and `X-Amzn-*` headers are prohibited except `X-Amzn-Bedrock-AgentCore-Runtime-Custom-*`. Keep allowlists minimal. Ref: https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/gateway-headers.html
- **Interceptors**: optional Lambda interceptors at `REQUEST`/`RESPONSE` points for request validation / DLP — useful as a security control; the interceptor Lambda's own role should be least-privilege.

---

### Memory data retention & strategies

- **Retention**: `event_expiry_duration` is **required**, 7–365 days. Opinionated default: a finite value (e.g. 90) — never indefinite. Drives data minimization/compliance.
- **Strategies** (`aws_bedrockagentcore_memory_strategy`): `SEMANTIC`, `SUMMARIZATION`, `USER_PREFERENCE`, `EPISODIC`, `CUSTOM`. Limits: max 6 strategies per memory; only one of each built-in type; multiple `CUSTOM` allowed. `CUSTOM` strategies invoke foundation models (extraction/consolidation) and require `memory_execution_role_arn` with Bedrock invoke perms.
- **Namespaces**: scope memory with namespace templates (e.g. `{sessionId}`, `/strategies/{memoryStrategyId}/actors/{actorId}/sessions/{sessionId}`) to isolate per-actor/session data — a tenancy/isolation control.
- **Encryption**: set `encryption_key_arn` to the module CMK (see KMS section).

---

### Identity — workload identity, credential providers, OAuth

- **Workload identity** (`aws_bedrockagentcore_workload_identity`): names the agent's identity and constrains OAuth redirect targets via `allowed_resource_oauth2_return_urls`. Keep the return-URL allowlist tight (exact callback URLs only) to prevent open-redirect/token-theft. Runtime and Gateway also auto-expose `workload_identity_details.workload_identity_arn`.
- **Credential providers**: OAuth2 (`aws_bedrockagentcore_oauth2_credential_provider`, vendors `CustomOauth2`/`GithubOauth2`/`GoogleOauth2`/`Microsoft`/`SalesforceOauth2`/`SlackOauth2`) and API key (`aws_bedrockagentcore_api_key_credential_provider`). Both store the secret in **AWS Secrets Manager** and export `*_secret_arn` — never inline-store secrets elsewhere.
- **Terraform secret hygiene (opinionated)**: default to the **write-only** arguments — `api_key_wo` + `api_key_wo_version`, and `client_id_wo`/`client_secret_wo` + `client_credentials_wo_version` (Terraform ≥ 1.11). These keep secrets out of state/plan output. Document the version-bump-to-rotate pattern. Avoid the plain `api_key`/`client_secret` args (visible in plan/state).
- **Token vault CMK**: customer-managed by default (`aws_bedrockagentcore_token_vault_cmk` with `CustomerManagedKey`) so stored OAuth/API-key material is encrypted under your CMK.
- **OAuth grant selection**: `CLIENT_CREDENTIALS` for machine-to-machine; `AUTHORIZATION_CODE` (with `default_return_url`) for user-delegated 3-legged flows. Request minimal `scopes`.

---

### Service quotas & regional availability

- **Memory strategy limits** (hard, validated): max 6 strategies/memory; one each of `SEMANTIC`/`SUMMARIZATION`/`USER_PREFERENCE`/`EPISODIC`; multiple `CUSTOM`. Event expiry 7–365 days.
- **Runtime**: up to 5 mounted filesystems per runtime; `code` entry point 1–2 elements; code runtimes `PYTHON_3_10`–`PYTHON_3_13`; container image must be in **ECR in the same account/region**.
- **Gateway**: 1–2 interceptors; MCP `session_timeout_in_seconds` 900–28800; `metadata_configuration` allowlists max 10 entries each.
- **Workload identity name**: 3–255 chars, alphanumeric + `-._`.
- **Regional availability**: AgentCore is GA in a subset of regions (notably `us-east-1`, `us-west-2`, plus expanding EU/AP regions). The module must **not** hard-code a region and should let the provider/`region` arg drive placement; consumers should confirm AgentCore + the chosen foundation models are available in their target region. Soft service quotas (number of runtimes/gateways/memories per account) are adjustable via Service Quotas — treat as account-level, outside module scope.

---

### Rationale

The provider examples for `aws_bedrockagentcore_agent_runtime`, `_memory`, `_gateway`, and `_gateway_target` all consistently use the `bedrock-agentcore.amazonaws.com` service principal and an ECR-pull + STS-assume pattern, confirming the trust/permission shape. AWS publishes the managed policy `AmazonBedrockAgentCoreMemoryBedrockModelInferenceExecutionRolePolicy` (surfaced directly in the Memory resource example), confirming model-inference needs for memory strategies. KMS args (`encryption_key_arn`, `kms_key_arn`, token-vault `CustomerManagedKey`) exist on exactly the components AWS documents as encryptable at rest. Credential providers explicitly back secrets with Secrets Manager (`*_secret_arn`) and offer write-only Terraform args — the secure production path. The gateway-headers AWS doc URL and schema-enforced header restrictions confirm the inbound/outbound auth and propagation hardening guidance. OTEL/X-Ray wiring is evidenced by the `opentelemetry-instrument` entry-point example and the X-Ray permission needs.

### Alternatives Considered

| Alternative | Why Not |
|-------------|---------|
| AWS-managed (service) encryption everywhere | Less control/auditability; module defaults to customer-managed CMK (overridable to AWS-managed) |
| `VPC` network mode as default | Adds subnet/SG/NAT complexity and egress cost; `PUBLIC` (AWS-managed egress) is the simpler secure default, `VPC` exposed as override for private-connectivity needs |
| Single shared execution role for all components | Violates least privilege; per-component roles limit blast radius |
| Plain `api_key`/`client_secret` Terraform args | Leak secrets into state/plan; write-only (`*_wo`) args are the secure default |
| `AWS_IAM`-only gateway auth | Fine for AWS-internal callers but JWT/OIDC needed for external user-facing agents; expose both, require one |
| Indefinite memory retention | Not supported (7–365 cap) and poor data-minimization; default to a finite retention |

### Sources

- Terraform AWS provider (v6.49.0) Bedrock AgentCore resources: `aws_bedrockagentcore_agent_runtime`, `_agent_runtime_endpoint`, `_gateway`, `_gateway_target`, `_memory`, `_memory_strategy`, `_workload_identity`, `_oauth2_credential_provider`, `_api_key_credential_provider`, `_token_vault_cmk` — https://registry.terraform.io/providers/hashicorp/aws/latest/docs
- AWS Bedrock AgentCore Developer Guide — Gateway request headers: https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/gateway-headers.html
- AWS Bedrock AgentCore Developer Guide (Identity, Memory, Runtime, Observability, IAM): https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/
- AWS managed policy `AmazonBedrockAgentCoreMemoryBedrockModelInferenceExecutionRolePolicy` (referenced in provider Memory example)
- AWS KMS confused-deputy / `aws:SourceAccount` & `aws:SourceArn` guidance: https://docs.aws.amazon.com/IAM/latest/UserGuide/confused-deputy.html
- Terraform write-only (ephemeral) arguments: https://developer.hashicorp.com/terraform/language/resources/ephemeral#write-only-arguments
