# Complete AgentCore Deployment

Full usage of `terraform-aws-agentcore` with every feature enabled: the always-on
runtime, a CUSTOM_JWT MCP gateway fronting a Lambda tool target, an AgentCore
memory store with a built-in SEMANTIC strategy, and identity (customer-managed
token-vault CMK plus API-key and OAuth2 credential providers).

All ARNs/URIs in this example are placeholder-but-valid; replace them with your
own before applying.

## Usage

```hcl
module "agentcore" {
  source = "../../"

  name          = "complete-agent"
  container_uri = "111122223333.dkr.ecr.us-east-1.amazonaws.com/complete-agent:latest"

  create_gateway            = true
  gateway_authorizer_type   = "CUSTOM_JWT"
  gateway_jwt_discovery_url = "https://issuer.example.com/.well-known/openid-configuration"
  gateway_protocol_type     = "MCP"

  gateway_targets = {
    lambda_tool = {
      target_configuration = {
        mcp = { lambda = { lambda_arn = "arn:aws:lambda:us-east-1:111122223333:function:agent-tool" } }
      }
      credential_provider_configuration = { gateway_iam_role = {} }
    }
  }

  create_memory     = true
  memory_strategies = { semantic = { type = "SEMANTIC", namespaces = ["/actors/{actorId}"] } }

  create_identity = true
  api_key_credential_providers = {
    weather = { api_key_wo = "placeholder-api-key", api_key_wo_version = 1 }
  }

  tags = { Environment = "example" }
}
```
