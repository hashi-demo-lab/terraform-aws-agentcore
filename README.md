# terraform-aws-agentcore

Opinionated, secure-by-default Terraform module for a complete
[Amazon Bedrock AgentCore](https://aws.amazon.com/bedrock/agentcore/) stack.

## Overview

This module provisions a governed footprint for teams deploying containerized AI
agents. It always creates an always-on agent **Runtime** from a consumer-supplied
container image, and optionally layers on a **Gateway** (to expose tools over
MCP/HTTP), persistent **Memory** (cross-session agent state with bounded
retention), and explicit **Identity** primitives (a customer-managed token-vault
encryption key plus outbound credential providers).

Platform and application teams consume it to stand up an AgentCore footprint —
customer-managed encryption, least-privilege per-component execution roles, and
CloudWatch observability — without each consumer re-deriving the IAM, KMS, and
confused-deputy guard wiring that AgentCore requires.

## Architecture & Features

| Component | Toggle | Default | What it provisions |
|-----------|--------|---------|--------------------|
| Runtime | always-on | — | `aws_bedrockagentcore_agent_runtime` from `container_uri`, plus an optional invoke endpoint (`create_runtime_endpoint`). |
| Encryption (KMS) | `create_kms_key` | `true` | Customer-managed CMK with rotation, key policy, and alias; wired to Gateway, Memory, the Identity token vault, and CloudWatch log groups. |
| Execution roles (IAM) | `create_execution_role` | `true` | Per-component least-privilege roles (Runtime / Gateway / Memory) with confused-deputy trust guards and resource-scoped policies. |
| Observability | `enable_observability` | `true` | CMK-encrypted, retention-bounded CloudWatch log groups + scoped Logs/Metrics/X-Ray permissions. |
| Gateway | `create_gateway` | `false` | `aws_bedrockagentcore_gateway` (authenticated only) + `for_each` targets. |
| Memory | `create_memory` | `false` | `aws_bedrockagentcore_memory` (finite retention) + `for_each` strategies. |
| Identity | `create_identity` | `false` | Token-vault CMK + API-key / OAuth2 credential providers. |

The four creation toggles — `create_gateway`, `create_memory`, and
`create_identity` (default `false`), alongside the always-on Runtime — let
consumers opt into exactly the surface they need. `create_kms_key` and
`create_execution_role` (default `true`) follow a **create-vs-supply** pattern:
set them to `false` and pass an existing `kms_key_arn` / `*_execution_role_arn`
to bring your own.

### Network mode

The module operates in **`PUBLIC`** (AWS-managed) network mode only this
iteration. `PUBLIC` refers to AWS-managed egress connectivity, **not** an open
inbound surface: gateway inbound auth is mandatory and runtime invoke requires
workload identity / IAM. The `network_mode` input is validated to `PUBLIC` only
but is shaped so a future `VPC` value can be added without a breaking change.

## Usage

Minimal, runtime-only deployment with secure defaults (customer-managed KMS, a
least-privilege execution role, and CloudWatch observability are all on):

```hcl
module "agentcore" {
  source = "github.com/your-org/terraform-aws-agentcore"

  name          = "myagent"
  container_uri = "111122223333.dkr.ecr.us-east-1.amazonaws.com/myagent:latest"
}
```

See the `examples/` directory for a basic runtime-only example and a complete
example enabling the Gateway, Memory, and Identity features.

## Security

- **Encryption at rest.** A customer-managed KMS CMK is created by default
  (`create_kms_key = true`, `enable_key_rotation = true`) and wired to the
  Gateway (`kms_key_arn`), Memory (`encryption_key_arn`), the Identity token
  vault (`token_vault_cmk` with `key_type = "CustomerManagedKey"`), and the
  CloudWatch log groups. Encryption is always on — supplying no module key only
  switches to AWS-managed encryption, never off.
- **IAM least privilege & confused-deputy guards.** Per-component execution
  roles trust only `bedrock-agentcore.amazonaws.com`, constrained by
  `aws:SourceAccount` and `aws:SourceArn` to defeat the confused-deputy problem.
  Permissions are resource-scoped (image-scoped ECR pull, namespace-scoped
  `cloudwatch:PutMetricData`, model-scoped Bedrock invoke, `kms:ViaService`-scoped
  KMS, secret-ARN-scoped `secretsmanager:GetSecretValue`). The KMS key policy
  applies matching `kms:ViaService` / `kms:CallerAccount` / `kms:GrantIsForAWSResource`
  conditions.
- **Write-only credential arguments.** API-key and OAuth2 credential providers
  use write-only (`*_wo`) arguments so secrets never enter Terraform state or
  plan output; secret material materializes in Secrets Manager encrypted under
  the token-vault CMK. Secret-bearing variables and `*_secret_arn` outputs are
  marked `sensitive`.
- **Authenticated inbound only.** Any Gateway created requires authentication
  (`AWS_IAM` or `CUSTOM_JWT`); there is no anonymous option.
- **Bounded retention.** Memory retention is finite (7–365 days) and log groups
  are retention-bounded — never indefinite.

## Notes & Caveats

These are open considerations carried from the module design (Section 7):

- **CloudWatch log-group pre-create race.** With `enable_observability = true`
  the module pre-creates the `/aws/bedrock-agentcore/...` log groups so it can
  enforce CMK encryption and bounded retention. AgentCore may also auto-create
  these groups, so pre-creation can race. If apply-time conflicts surface, the
  fallback is service-created groups plus a CloudWatch Logs resource policy for
  CMK/retention.
- **VPC / private networking is deferred.** Only `PUBLIC` network mode is
  implemented this iteration. The interface is forward-compatible with a future
  `VPC` value, but no `subnets` / `security_groups` inputs are surfaced now.
- **ECR image is out of scope.** The module does not build container images or
  manage `aws_ecr_repository`; the consumer supplies a ready `container_uri`.
  Account-level prerequisites (CloudWatch Transaction Search enablement, Service
  Quota increases) are also flagged but not toggled by the module.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.8 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | >= 6.21 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_aws"></a> [aws](#provider\_aws) | 6.49.0 |

## Modules

No modules.

## Resources

| Name | Type |
|------|------|
| [aws_bedrockagentcore_agent_runtime.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/bedrockagentcore_agent_runtime) | resource |
| [aws_bedrockagentcore_agent_runtime_endpoint.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/bedrockagentcore_agent_runtime_endpoint) | resource |
| [aws_bedrockagentcore_api_key_credential_provider.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/bedrockagentcore_api_key_credential_provider) | resource |
| [aws_bedrockagentcore_gateway.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/bedrockagentcore_gateway) | resource |
| [aws_bedrockagentcore_gateway_target.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/bedrockagentcore_gateway_target) | resource |
| [aws_bedrockagentcore_memory.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/bedrockagentcore_memory) | resource |
| [aws_bedrockagentcore_memory_strategy.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/bedrockagentcore_memory_strategy) | resource |
| [aws_bedrockagentcore_oauth2_credential_provider.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/bedrockagentcore_oauth2_credential_provider) | resource |
| [aws_bedrockagentcore_token_vault_cmk.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/bedrockagentcore_token_vault_cmk) | resource |
| [aws_bedrockagentcore_workload_identity.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/bedrockagentcore_workload_identity) | resource |
| [aws_cloudwatch_log_group.gateway](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
| [aws_cloudwatch_log_group.runtime](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
| [aws_iam_role.gateway](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.memory](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.runtime](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.gateway](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy.runtime](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy_attachment.memory_inference](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_kms_alias.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_alias) | resource |
| [aws_kms_key.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_key) | resource |
| [aws_kms_key_policy.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_key_policy) | resource |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_iam_policy_document.agentcore_trust](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.gateway](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.kms](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.runtime](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_partition.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/partition) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_allowed_resource_oauth2_return_urls"></a> [allowed\_resource\_oauth2\_return\_urls](#input\_allowed\_resource\_oauth2\_return\_urls) | Exact OAuth2 redirect URLs allowed for the standalone workload identity. | `set(string)` | `[]` | no |
| <a name="input_api_key_credential_providers"></a> [api\_key\_credential\_providers](#input\_api\_key\_credential\_providers) | Map of API-key credential providers (write-only secret args). Requires create\_identity = true. | <pre>map(object({<br/>    api_key_wo         = string<br/>    api_key_wo_version = number<br/>  }))</pre> | `{}` | no |
| <a name="input_container_uri"></a> [container\_uri](#input\_container\_uri) | Consumer-provided ECR container image URI (<acct>.dkr.ecr.<region>.amazonaws.com/<repo>:<tag>) for the runtime. | `string` | n/a | yes |
| <a name="input_create_execution_role"></a> [create\_execution\_role](#input\_create\_execution\_role) | Create per-component least-privilege execution roles. | `bool` | `true` | no |
| <a name="input_create_gateway"></a> [create\_gateway](#input\_create\_gateway) | Create an AgentCore Gateway. | `bool` | `false` | no |
| <a name="input_create_identity"></a> [create\_identity](#input\_create\_identity) | Provision the customer-managed token-vault CMK and credential providers. Does not gate the implicit workload identity. | `bool` | `false` | no |
| <a name="input_create_kms_key"></a> [create\_kms\_key](#input\_create\_kms\_key) | Create a customer-managed KMS key for at-rest encryption. | `bool` | `true` | no |
| <a name="input_create_memory"></a> [create\_memory](#input\_create\_memory) | Create an AgentCore Memory store. | `bool` | `false` | no |
| <a name="input_create_runtime_endpoint"></a> [create\_runtime\_endpoint](#input\_create\_runtime\_endpoint) | Create a named invoke endpoint for the runtime. | `bool` | `true` | no |
| <a name="input_create_standalone_workload_identity"></a> [create\_standalone\_workload\_identity](#input\_create\_standalone\_workload\_identity) | Create an explicit standalone workload identity (for custom OAuth2 return URLs). | `bool` | `false` | no |
| <a name="input_description"></a> [description](#input\_description) | Human-readable description applied to created AgentCore resources. | `string` | `null` | no |
| <a name="input_enable_key_rotation"></a> [enable\_key\_rotation](#input\_enable\_key\_rotation) | Enable annual rotation on the module-created KMS key. | `bool` | `true` | no |
| <a name="input_enable_observability"></a> [enable\_observability](#input\_enable\_observability) | Create CMK-encrypted, retention-bounded CloudWatch log groups and add Logs/Metrics/X-Ray statements to the execution role. | `bool` | `true` | no |
| <a name="input_environment_variables"></a> [environment\_variables](#input\_environment\_variables) | Environment variables injected into the runtime container. | `map(string)` | `{}` | no |
| <a name="input_gateway_authorizer_type"></a> [gateway\_authorizer\_type](#input\_gateway\_authorizer\_type) | Gateway inbound auth type. Anonymous access is not permitted. | `string` | `"AWS_IAM"` | no |
| <a name="input_gateway_execution_role_arn"></a> [gateway\_execution\_role\_arn](#input\_gateway\_execution\_role\_arn) | Existing gateway execution role ARN. | `string` | `null` | no |
| <a name="input_gateway_jwt_allowed_audience"></a> [gateway\_jwt\_allowed\_audience](#input\_gateway\_jwt\_allowed\_audience) | Allowed JWT audiences for a CUSTOM\_JWT gateway. | `list(string)` | `[]` | no |
| <a name="input_gateway_jwt_allowed_clients"></a> [gateway\_jwt\_allowed\_clients](#input\_gateway\_jwt\_allowed\_clients) | Allowed JWT client IDs for a CUSTOM\_JWT gateway. | `list(string)` | `[]` | no |
| <a name="input_gateway_jwt_discovery_url"></a> [gateway\_jwt\_discovery\_url](#input\_gateway\_jwt\_discovery\_url) | OIDC discovery URL for CUSTOM\_JWT gateways. | `string` | `null` | no |
| <a name="input_gateway_protocol_type"></a> [gateway\_protocol\_type](#input\_gateway\_protocol\_type) | Gateway protocol. MCP for tool gateways; null (omitted) required for HTTP-to-runtime targets. | `string` | `null` | no |
| <a name="input_gateway_targets"></a> [gateway\_targets](#input\_gateway\_targets) | Map of gateway targets keyed by stable name. Each entry: exactly one of mcp/http; credential\_provider\_configuration present for lambda/openapi/smithy, absent for unauth mcp\_server. | `any` | `{}` | no |
| <a name="input_kms_key_arn"></a> [kms\_key\_arn](#input\_kms\_key\_arn) | Existing CMK ARN to use when create\_kms\_key = false. | `string` | `null` | no |
| <a name="input_log_retention_in_days"></a> [log\_retention\_in\_days](#input\_log\_retention\_in\_days) | Retention for module-created CloudWatch log groups. | `number` | `90` | no |
| <a name="input_memory_event_expiry_duration"></a> [memory\_event\_expiry\_duration](#input\_memory\_event\_expiry\_duration) | Days until memory events expire (finite retention). | `number` | `90` | no |
| <a name="input_memory_execution_role_arn"></a> [memory\_execution\_role\_arn](#input\_memory\_execution\_role\_arn) | Existing memory execution role ARN (required for model-backed CUSTOM strategies). | `string` | `null` | no |
| <a name="input_memory_strategies"></a> [memory\_strategies](#input\_memory\_strategies) | Map of memory strategies keyed by stable name (max 6 per memory). | `any` | `{}` | no |
| <a name="input_name"></a> [name](#input\_name) | Base name used as a prefix for all resources. Runtime names auto-convert hyphens to underscores. | `string` | n/a | yes |
| <a name="input_network_mode"></a> [network\_mode](#input\_network\_mode) | Runtime network mode. Only PUBLIC supported this iteration; reserved for future VPC. | `string` | `"PUBLIC"` | no |
| <a name="input_oauth2_credential_providers"></a> [oauth2\_credential\_providers](#input\_oauth2\_credential\_providers) | Map of OAuth2 credential providers (write-only secret args). Requires create\_identity = true. | `any` | `{}` | no |
| <a name="input_runtime_endpoint_version"></a> [runtime\_endpoint\_version](#input\_runtime\_endpoint\_version) | Pin the runtime endpoint to a specific runtime version. Null leaves it unpinned (tracks latest). | `string` | `null` | no |
| <a name="input_runtime_execution_role_arn"></a> [runtime\_execution\_role\_arn](#input\_runtime\_execution\_role\_arn) | Existing runtime execution role ARN when create\_execution\_role = false. | `string` | `null` | no |
| <a name="input_server_protocol"></a> [server\_protocol](#input\_server\_protocol) | Runtime inbound application protocol. | `string` | `"MCP"` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags merged with module defaults onto every taggable resource. | `map(string)` | `{}` | no |
| <a name="input_workload_identity_name"></a> [workload\_identity\_name](#input\_workload\_identity\_name) | Name for the standalone workload identity. | `string` | `null` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_agent_runtime_arn"></a> [agent\_runtime\_arn](#output\_agent\_runtime\_arn) | ARN of the agent runtime. |
| <a name="output_agent_runtime_endpoint_arn"></a> [agent\_runtime\_endpoint\_arn](#output\_agent\_runtime\_endpoint\_arn) | ARN of the runtime endpoint; null when not created. |
| <a name="output_agent_runtime_id"></a> [agent\_runtime\_id](#output\_agent\_runtime\_id) | ID of the agent runtime. |
| <a name="output_agent_runtime_version"></a> [agent\_runtime\_version](#output\_agent\_runtime\_version) | Current version of the agent runtime. |
| <a name="output_api_key_credential_provider_arns"></a> [api\_key\_credential\_provider\_arns](#output\_api\_key\_credential\_provider\_arns) | Map of name to API-key credential provider ARN. |
| <a name="output_api_key_secret_arns"></a> [api\_key\_secret\_arns](#output\_api\_key\_secret\_arns) | Map of name to Secrets Manager secret ARN for API-key providers. |
| <a name="output_execution_role_arn"></a> [execution\_role\_arn](#output\_execution\_role\_arn) | Runtime execution role ARN (created or supplied). |
| <a name="output_gateway_arn"></a> [gateway\_arn](#output\_gateway\_arn) | Gateway ARN; null when disabled. |
| <a name="output_gateway_id"></a> [gateway\_id](#output\_gateway\_id) | Gateway ID; null when disabled. |
| <a name="output_gateway_target_ids"></a> [gateway\_target\_ids](#output\_gateway\_target\_ids) | Map of target name to target ID; empty when disabled. |
| <a name="output_gateway_url"></a> [gateway\_url](#output\_gateway\_url) | Gateway MCP/HTTP URL; null when disabled. |
| <a name="output_kms_key_arn"></a> [kms\_key\_arn](#output\_kms\_key\_arn) | Effective CMK ARN used for encryption (created or supplied); null if neither. |
| <a name="output_memory_arn"></a> [memory\_arn](#output\_memory\_arn) | Memory ARN; null when disabled. |
| <a name="output_memory_id"></a> [memory\_id](#output\_memory\_id) | Memory ID; null when disabled. |
| <a name="output_memory_strategy_ids"></a> [memory\_strategy\_ids](#output\_memory\_strategy\_ids) | Map of strategy name to strategy ID; empty when disabled. |
| <a name="output_oauth2_client_secret_arns"></a> [oauth2\_client\_secret\_arns](#output\_oauth2\_client\_secret\_arns) | Map of name to Secrets Manager client-secret ARN. |
| <a name="output_oauth2_credential_provider_arns"></a> [oauth2\_credential\_provider\_arns](#output\_oauth2\_credential\_provider\_arns) | Map of name to OAuth2 credential provider ARN. |
| <a name="output_standalone_workload_identity_arn"></a> [standalone\_workload\_identity\_arn](#output\_standalone\_workload\_identity\_arn) | Standalone workload identity ARN; null when disabled. |
| <a name="output_token_vault_cmk_key_arn"></a> [token\_vault\_cmk\_key\_arn](#output\_token\_vault\_cmk\_key\_arn) | CMK ARN applied to the Identity token vault; null when disabled. |
| <a name="output_workload_identity_arn"></a> [workload\_identity\_arn](#output\_workload\_identity\_arn) | Implicit workload identity ARN emitted by the runtime. |
<!-- END_TF_DOCS -->

## License

Apache License 2.0. See [LICENSE](LICENSE).
