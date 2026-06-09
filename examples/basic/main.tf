###############################################################################
# Basic example — runtime only, secure defaults.
#
# Provisions just the always-on AgentCore runtime (plus its CMK, execution role,
# and observability log groups via module defaults). Gateway, memory, and
# identity features are left disabled.
###############################################################################

module "agentcore" {
  source = "../../"

  name          = "basic-agent"
  container_uri = "111122223333.dkr.ecr.us-east-1.amazonaws.com/basic-agent:latest"
}
