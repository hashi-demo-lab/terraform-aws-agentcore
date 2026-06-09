# Basic AgentCore Runtime

Minimal usage of `terraform-aws-agentcore`: an always-on AgentCore runtime with
secure defaults (customer-managed KMS key, least-privilege execution role, and
CMK-encrypted, retention-bounded CloudWatch log groups). Gateway, memory, and
identity features are disabled.

## Usage

```hcl
module "agentcore" {
  source = "../../"

  name          = "basic-agent"
  container_uri = "111122223333.dkr.ecr.us-east-1.amazonaws.com/basic-agent:latest"
}
```
