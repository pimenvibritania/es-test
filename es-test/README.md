# Paid Tier — Secure 3-Node ElasticSearch Cluster (AWS, NOT free)

Status: **NOT YET applied/tested**. This is the "extend to production-grade" path described in the take-home answers — it intentionally uses paid AWS components (NAT Gateway, customer-managed KMS CMK, Secrets Manager) that the free-tier variant avoids.

## What this adds on top of free-tier
- **3x EC2** nodes spread across 2 Availability Zones, all master-eligible + data nodes (quorum = 2/3, tolerates 1 node down)
- **Private subnets** + NAT Gateway (nodes have no public IP; outbound internet via NAT)
- **Transport-layer TLS (port 9300)** with mutual auth between nodes — required for multi-node security, not needed in single-node
- **Customer-managed KMS CMK** for EBS + Secrets Manager (vs AWS-managed key in free-tier) for granular audit/key rotation control
- **AWS Secrets Manager** (vs SSM Parameter Store) for the `elastic` password — supports automatic rotation
- Security Group for port 9300 restricted to **self-referencing** (only members of the same SG can talk to each other)

## Cost impact vs free-tier (estimates, us-east-1, ASSUMPTION — verify with AWS Pricing Calculator)
| Component | Est. cost/month | Why it's here |
|---|---|---|
| 2 extra EC2 (t3.micro beyond the 1 free) | ~$15 | 3-node HA quorum |
| NAT Gateway | ~$32 + data processed | Private subnet egress without public IP |
| Secrets Manager (1 secret) | ~$0.40 | Automatic rotation support |
| KMS CMK | ~$1 | Customer-managed key, own audit trail |
| **Total extra vs free-tier** | **~$48+/month** | |

## Usage
```bash
cd terraform
terraform init
terraform plan -var="allowed_cidr=<your-ip>/32"
terraform apply -var="allowed_cidr=<your-ip>/32"
```

## Verification
```bash
# from an instance inside the VPC (e.g. via SSM into any of the 3 nodes)
SECRET=$(aws secretsmanager get-secret-value --secret-id elasticsearch/paid-tier/elastic-password --query SecretString --output text)
curl -k -u elastic:$SECRET https://<any-node-private-ip>:9200/_cluster/health?pretty
# expect: "number_of_nodes": 3, "status": "green"
```

## Zero-downtime node replacement (rolling)
```bash
curl -k -u elastic:$SECRET -X PUT https://<node-ip>:9200/_cluster/settings \
  -H 'Content-Type: application/json' -d '{"transient":{"cluster.routing.allocation.enable":"none"}}'
# stop/replace/start the target node instance
curl -k -u elastic:$SECRET -X PUT https://<node-ip>:9200/_cluster/settings \
  -H 'Content-Type: application/json' -d '{"transient":{"cluster.routing.allocation.enable":"all"}}'
# wait for status green before repeating on the next node
```
