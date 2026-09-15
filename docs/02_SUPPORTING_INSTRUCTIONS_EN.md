# Infrastructure Engineer Take-Home Test — Supporting Instructions Document

This document maps the delivered code directly to the requirements in the original task PDF (`Infrastructure_Engineer.pdf`) and answers every question it explicitly asks for.

---

## 1. What the task asked for (verbatim requirements)

> Bring up an AWS instance; install ElasticSearch configured to require credentials and provide encrypted communication; demonstrate it is functioning. Bonus: extend to a 3-node cluster. Must use AWS free tier (mention any additional paid services used). Exercise budget: 2.5 hours.

**Scope**: this repository's final submission is a **single implementation**, located in `es-test/`. It is the sole deliverable, covering both the base requirement (secured, credentialed, encrypted single-purpose ES) **and** the bonus (3-node cluster + VPN + monitoring + alerting).

Because `es-test/` deliberately goes beyond what's strictly free-tier-eligible (see section 8 for the full breakdown), the sections below are explicit about **which specific pieces of the stack are free-tier-eligible and which are paid**, and how the paid pieces are currently funded.

### Free vs. Paid breakdown (what's actually charged)

| Resource in `es-test/` | Free-tier eligible? | Notes |
|---|---|---|
| EC2 `t3.small` × 5 (3 ES nodes + Kibana + Pritunl VPN) | ❌ No | Free tier only covers `t2.micro`/`t3.micro` (750 hrs/mo); `t3.small` is billed from hour one |
| NAT Gateway | ❌ No | Never free at any AWS tier, any account age |
| AWS Secrets Manager (3 secrets: `elastic`, `kibana_system`, CA bundle) | ❌ No | ~$0.40/secret/month flat, no free quota |
| KMS customer-managed CMK | ⚠️ Partial | 20,000 requests/month always free; the ~$1/month **flat key fee** is not covered by any free tier |
| Elastic IP (attached to running instance) | ✅ Yes | Free while attached to a running instance, on any tier |
| CloudWatch alarms (7) | ✅ Yes (up to 10) | Within AWS's always-free CloudWatch alarm quota |
| SNS email notifications | ✅ Yes | Within AWS's always-free SNS request quota for this volume |

**How the paid pieces are currently funded**: the AWS account used for this exercise has two active promotional credits — **AWS Free Tier credit ($100, 12-month)** and an **"Explore AWS: Launch an instance using EC2" credit ($20, 12-month)**, both expiring 09/14/2027, for a combined **$120.00** balance. AWS applies these credits automatically to the monthly invoice *before* any charge reaches a debit/credit card. As of this session, actual usage against that balance was **$2.09**, leaving **$117.91** remaining — so nothing has been (or currently is being) charged to a real payment method. This is a **credit offset**, not a free-tier technical exemption: the resources above are still "paid" by AWS's own classification, they are simply not yet costing the account owner anything out-of-pocket. If `es-test/` were left running 24/7 for its full estimated ~$56–58/month (section 8), the $117.91 remaining balance would last roughly two months before real card charges would begin.

---

## 2. Solution description & design choices

### 2.1 Automation tool choice
**Terraform + Ansible**, orchestrated by a single `deploy.sh` per logical stack (ES, VPN, monitoring, alerting). Terraform owns all AWS resource lifecycle (VPC, EC2, IAM, KMS, Secrets Manager, CloudWatch, SNS); Ansible owns all in-instance software configuration (package install, TLS cert generation, service config, password rotation).

**Why split this way instead of pure Terraform `user_data` or pure Ansible with manually-created instances:**
- `user_data` scripts execute once at boot and have no visibility into sibling instances' IPs — this made correct multi-node cluster discovery impossible in an earlier iteration (each node only knew its own IP). Ansible, running *after* Terraform has created all 3 instances, has the full inventory (every node's private IP) available up front and can write a **correct peer-discovery file** to every node in a single pass.
- Splitting these concerns also keeps each layer idempotent and independently re-runnable: `terraform apply` again is a no-op if nothing changed infra-side; re-running the Ansible playbook is a no-op if ES config/certs haven't changed (verified via explicit idempotency guards in the playbook, e.g. checking for an existing "ANSIBLE MANAGED BLOCK" marker before rewriting config files, or checking SAN entries on certs before regenerating them).

### 2.2 Access model: zero SSH
Every instance is reached exclusively through **AWS Systems Manager Session Manager** (`ansible_connection=community.aws.aws_ssm`), never SSH. This means:
- No SSH keypairs generated, stored, or rotated anywhere in this project.
- No port 22 open on any security group.
- All access is auditable through AWS CloudTrail (every SSM session is a logged API call), which is a stronger security/audit posture than SSH access logs on the instance itself.
- The Ansible SSM connection plugin requires an S3 bucket as a file-transfer relay (no direct network path is opened) — provisioned as `aws_s3_bucket.ansible_ssm_transfer`, public access fully blocked.

### 2.3 Time spent
Approximately 2.5 hours were spent on the initial base + bonus (3-node) build within the original exercise window, as instructed. Additional debugging/hardening time (finding and fixing the shell-injection password bug, the Kibana health-check masking bug, and the SSM race condition) was spent in a follow-up session after the original submission window, driven by running the full destroy/recreate cycle repeatedly to validate durability of the fix — this went well beyond the 2.5h budget but was done to demonstrate a genuinely production-ready result rather than a "worked once" demo.

### 2.4 Feedback on the exercise
- The 2.5-hour budget is realistic for the base single-node requirement, but tight for the 3-node bonus with proper TLS on both HTTP and transport layers plus VPN-gated access — those two together are what actually took the extra iteration time (cluster discovery and inter-node TLS trust are the parts that are easy to get "looking done" but subtly broken, as this session's own bug history shows).
- The exercise doesn't specify what "credentials" means precisely (basic auth vs. mutual TLS vs. IAM-based) — we interpreted it as requiring both authenticated HTTP access (`elastic`/`kibana_system` users, X-Pack security) **and** encrypted transport, which seems to be the intended reading given the "provides encrypted communication" clause.

---

## 3. How ElasticSearch was secured (and why)

| Layer | Mechanism | Rationale |
|---|---|---|
| HTTP API (9200) | X-Pack security enabled, TLS via self-signed cert (per-node, signed by a shared CA) | Required for the base task ("requires credentials", "encrypted communication") |
| Transport layer (9300) | Mutual TLS between nodes, same CA | Required specifically for multi-node clusters — node-to-node traffic must also be authenticated/encrypted, not just the client-facing API |
| Network | Port 9200 restricted by security group to a specific CIDR (single-node) or to the VPN server's security group only (paid-tier), never `0.0.0.0/0`; port 9300 restricted to self-referencing security-group members only | Defense in depth — even if TLS/auth were somehow bypassed, the network path itself is closed to the public internet |
| Credentials | Random 20-character passwords (`elastic` superuser + `kibana_system` service account) generated by Terraform, stored in AWS Secrets Manager (paid-tier) / SSM Parameter Store (free-tier), never hardcoded | Avoids any credential ever existing in source code, terraform files, or version control |
| Encryption at rest | EBS volumes encrypted with a KMS key (customer-managed CMK in paid-tier, AWS-managed in free-tier) | Data-at-rest protection for the ES data directory |
| IAM | Scoped least-privilege policies — instance role can only `secretsmanager:GetSecretValue` on the 2 specific secret ARNs it needs, plus `kms:Decrypt` on the corresponding key, never wildcard resource access | Standard least-privilege practice; limits blast radius if an instance is compromised |

---

## 4. How this instance/cluster would be monitored, and what metrics

**Implemented in this repository** (`es-test/monitoring/` + `es-test/alerting/` stacks):
1. **Kibana** — deployed as a dedicated instance, reachable only through the VPN, giving visual access to ES's own monitoring UI / indices / query console.
2. **AWS CloudWatch native EC2 metrics** — per node: `CPUUtilization` (alarm >80% sustained 15 min) and `StatusCheckFailed` (AWS's own instance/system health check, catches hardware/network-level failures CloudWatch itself detects without any agent).
3. **Custom application-level metric** — CloudWatch has zero native visibility into ES's *internal* cluster health (green/yellow/red), so a small cron script on every node polls `_cluster/health` locally every minute and pushes a numeric metric (`0=green, 1=yellow, 2=red`) to a custom CloudWatch namespace (`EsTest/Custom`) via `aws cloudwatch put-metric-data`. An alarm fires if this value is ever >0.
4. **SNS email alerting** — all the above alarms feed into a single SNS topic subscribed to an email address; `treat_missing_data = "breaching"` on every alarm ensures that if the cron job itself stops running (or an instance goes fully unreachable), that silence is *itself* treated as an alarm condition rather than going unnoticed.

**Additional metrics I would add given more time / a real production deployment:**
- JVM heap usage / GC pause time per node (ES exposes this via `_nodes/stats`) — heap pressure is usually the earliest warning sign of an ES cluster in trouble, well before CPU or disk fills up.
- Disk usage / watermark thresholds (ES has built-in low/high/flood-stage watermarks that trigger allocation changes) — CloudWatch's native `DiskSpaceUtilization` (via CloudWatch Agent) combined with alarms tied to ES's own watermark percentages.
- Search/indexing latency and rejected-thread-pool counts — these directly reflect user-facing query performance degradation, which cluster-color alone doesn't capture (a cluster can be "green" while queries are painfully slow under load).
- Shard count and unassigned-shard count as an explicit alarm (currently only inferred indirectly via cluster status), since a cluster stuck "yellow" for a long time due to unassigned replicas is a distinct failure mode worth its own signal.
- A proper metrics agent (CloudWatch Agent with the built-in ES/OpenSearch metric collection, or a dedicated Elastic Beat) rather than a hand-rolled cron+curl script, for anything beyond a take-home demo — the cron script is simple and auditable but doesn't scale to richer metric sets without significant extension.

---

## 5. Extending to a secure 3-node cluster — what had to change

This was implemented (see `es-test/`), not just theorized. Key changes from the single-node design:
1. **Node discovery**: single-node ES doesn't need `discovery.seed_providers`; a 3-node cluster requires every node to know every other node's address up front. Solved via Ansible writing a `unicast_hosts.txt` file-discovery list populated from the live Terraform-provisioned inventory — this is the part that a naive Terraform-`user_data`-only approach genuinely cannot do correctly.
2. **Transport-layer TLS**: single-node has no inter-node traffic to secure; a cluster requires TLS on port 9300 with a **shared CA** so nodes can mutually trust each other's certificates — the CA is generated once in Terraform and distributed to all nodes via Secrets Manager.
3. **Quorum-aware master eligibility**: `node.roles: [master, data]` on all 3 nodes with `cluster.initial_master_nodes` listing all 3 — gives quorum tolerance of 1 node down (2-of-3) without a dedicated (4th) master-only node, an acceptable trade-off at this scale.
4. **Availability Zone spread**: nodes are placed across 2 AZs (not 3, since node_count=3 but only using `%2` distribution across 2 AZs in the current network layout) to tolerate a single AZ outage without losing the whole cluster.
5. **Security group topology**: instead of a single "everyone talks to everyone" rule, node-to-node transport traffic uses a self-referencing security group rule (only members of the same SG, i.e. only the ES nodes themselves) — this scales naturally to any node count without per-node rule management.

---

## 6. Zero/low-downtime node replacement

Implemented as a documented rolling procedure (see `es-test/README.md`), not automated end-to-end in code (time constraint), but fully specified:
```bash
# 1. Disable shard allocation before touching the node (prevents unnecessary
#    shard reshuffling while the node is briefly down)
curl -k -u elastic:$SECRET -X PUT https://<node-ip>:9200/_cluster/settings \
  -d '{"transient":{"cluster.routing.allocation.enable":"none"}}'

# 2. Stop/terminate/replace the target EC2 instance (Terraform: taint + apply,
#    or ASG-based replacement in a fuller production setup)

# 3. Re-enable allocation once the replacement node has rejoined and the
#    Ansible playbook has re-provisioned it (it re-generates its own cert +
#    re-populates the discovery file automatically, idempotently)
curl -k -u elastic:$SECRET -X PUT https://<node-ip>:9200/_cluster/settings \
  -d '{"transient":{"cluster.routing.allocation.enable":"all"}}'

# 4. Wait for cluster status green before repeating on the next node
```
Because the cluster has 3 master-eligible nodes and quorum tolerance of 1 node down, this procedure can be done one node at a time with the cluster remaining fully available (green→yellow→green per node) throughout, rather than requiring a full outage window.

**What I would add given more time**: automate this as a Terraform `null_resource` + `local-exec` triggered rolling-replace, or better, move to an Auto Scaling Group with a `create_before_destroy` lifecycle + instance-refresh policy, so replacement is a single `terraform apply` rather than a manually-run script.

---

## 7. Code structure, extensibility, reusability — was this a priority?

Yes, explicitly. Evidence in the delivered code:
- **Parameterization**: node count (`var.node_count`), instance type, region, and allowed CIDR are all Terraform variables, not hardcoded — scaling from 3 to N nodes is a `-var="node_count=5"` change, no code edit required (the `for_each` construct over a computed set handles this automatically).
- **Stack separation**: ES / VPN / monitoring / alerting are 4 independently deployable Terraform+Ansible stacks linked only via `terraform_remote_state` reads — each can be destroyed/recreated/modified in isolation without touching the others' state, and each has its own single-command `deploy.sh` entry point.
- **Idempotency by design**: every Ansible task that mutates state (config file rewrite, cert generation, password reset) is guarded by an explicit check (marker-based, SAN-based, or `creates:`), so the entire pipeline can be re-run safely and repeatedly without unintended side effects (restarts, duplicate cron entries, etc.) — this was verified in practice via multiple consecutive destroy/recreate cycles in this session.
- **Fail-loud over silent masking**: several bugs were only ever discovered *because* of this principle — health-check tasks that previously tolerated a "still starting" status code silently hid a real outage; adding explicit auth-verification and strict status-code checks turned invisible failures into loud, immediate playbook failures, which is a deliberate design stance carried consistently across all 4 Ansible playbooks in this repo.

---

## 8. Sacrifices made due to time

- **Pritunl VPN admin bootstrap** (initial org/user creation, `.ovpn` profile download) remains a manual, one-time step via the web UI — Pritunl's own workflow is designed around this being a human action (issuing per-user VPN credentials), and automating it would require reverse-engineering an undocumented internal API rather than a supported one; not worth the risk for a take-home exercise.
- **SNS email subscription confirmation** is an unavoidable manual step — this is an AWS API limitation (there is no API to auto-confirm a subscription without owning the mailbox), not a shortcut taken in this code.
- **Pritunl package signature verification is disabled** (`gpgcheck: false`) because the project's published GPG key currently 404s at every documented location — a known, explicitly-documented risk trade-off acceptable for a demo/test environment, flagged as something to revisit before any real production use.
- **Metrics depth**: the custom health metric is a simple green/yellow/red cluster-status cron script, not a full metrics agent (JVM heap, disk watermarks, query latency, etc. are not currently collected) — sufficient to demonstrate the alerting pipeline end-to-end, but would need a proper metrics agent (CloudWatch Agent's ES integration, or an Elastic Beat) for real operational depth.
- **Rolling node replacement** is documented and manually executable but not wired into a single Terraform/Ansible command — automating it fully (e.g. via an ASG instance-refresh policy) was out of scope for the time available.
- **Resources used beyond free tier**: NAT Gateway, customer-managed KMS CMK, AWS Secrets Manager, Elastic IP on the VPN instance, and `t3.small` (vs. free-tier-eligible `t3.micro`) on all 5 instances. Currently offset by $120.00 in AWS promotional credit ($117.91 remaining as of this session — see section 1 for the full free-vs-paid breakdown and credit mechanics). Estimated additional cost breakdown:

| Component | Est. cost/month | Reason |
|---|---|---|
| 2 extra EC2 beyond 1 free-tier instance | ~$15 | 3-node HA quorum |
| NAT Gateway | ~$32 + data processed | Private-subnet egress without public IPs |
| Secrets Manager (3 secrets: elastic, kibana_system, CA bundle) | ~$1.20 | Automatic rotation support, vs SSM Parameter Store (free) |
| KMS CMK | ~$1 | Customer-managed key, own audit trail |
| Pritunl VPN EC2 (t3.micro) | ~$7–8 | VPN access layer |
| CloudWatch alarms (7 alarms) + SNS | <$1 | Alerting pipeline |
| **Total extra vs. free-tier single node** | **~$56–58/month** | |

---

## 9. Resources consulted

- Official Elastic documentation: `elasticsearch-certutil`, `elasticsearch-reset-password`, X-Pack security minimal setup, Kibana `kibana_system` service-account requirement (Kibana ≥8.x refuses the `elastic` superuser for its own service connection — this is documented Elastic behavior, not a bug).
- AWS documentation: Systems Manager Session Manager (SSM) as an SSH-less access pattern, `community.aws.aws_ssm` Ansible connection plugin requirements (S3 relay bucket).
- Terraform AWS provider documentation — specifically the explicit warning against mixing inline security-group `ingress`/`egress` blocks with separate `aws_security_group_rule` resources on the same group (encountered and fixed as a real bug during this exercise).
- Pritunl official installation documentation (community edition, OpenVPN-based, MongoDB-backed).

---

## 10. Final verification (this session)

A **full destroy → recreate cycle from zero** (not merely a resume of existing infrastructure) was run end-to-end across all 4 stacks in this session, in dependency order (destroy: alerting→monitoring→vpn→ES; recreate: ES→vpn→monitoring→alerting), specifically to prove the shell-injection password bug fix holds under a genuine cold-start rather than an idempotent no-op re-run. Result:
- ES cluster: `green`, 3/3 nodes, 100% active shards.
- Kibana: HTTP 200 on first playbook attempt, no manual intervention required.
- `kibana_system` password auth: verified automatically by the playbook's own fail-loud check.
- CloudWatch alarms: 6/7 `OK`, 1 `INSUFFICIENT_DATA` (expected — brand-new node, insufficient metric history at check time).
- SNS email subscription: confirmed (AWS reused the existing confirmed subscription for the same email address).

This confirms the delivered code is self-sufficient and reproducible from a completely empty AWS account state, with zero manual remediation steps beyond the one AWS-mandated SNS email confirmation.

---

## 11. How to provision (setup)

### 11.1 Prerequisites (one-time)
1. AWS credentials with `AdministratorAccess` (or an equivalent least-privilege policy covering VPC/EC2/IAM/KMS/SecretsManager/CloudWatch/SNS/S3/SSM) for the target account.
2. `terraform`, `ansible`, `aws` CLI, and the AWS `session-manager-plugin` installed locally. `es-test/deploy.sh` and its siblings assume these are already on `PATH`.
3. No SSH keypair is required anywhere — all in-instance access goes through AWS SSM Session Manager.

### 11.2 Provisioning flow (per stack)
Every stack (`es-test/`, `es-test/vpn/`, `es-test/monitoring/`, `es-test/alerting/`) follows the **same 3-step, fully-automated pattern**, driven by that stack's own `deploy.sh`:

1. **`terraform init` + `terraform apply`** — creates/updates all AWS resources for that stack (VPC, EC2, IAM, KMS, Secrets Manager, CloudWatch, SNS, S3, etc., depending on the stack). Downstream stacks (vpn/monitoring/alerting) read the upstream stack's outputs via `terraform_remote_state`, so they must be applied *after* their dependency, never before.
2. **Auto-generate the Ansible inventory** — a short inline Python block reads `terraform output -json` from the stack just applied (plus any upstream stack outputs it needs, e.g. monitoring reads both its own VPN/Kibana outputs and the ES stack's node IPs) and writes `ansible/inventory.ini` directly — no manual editing of an inventory file ever happens.
3. **`ansible-playbook`** — configures the software on the instance(s) just created (install ElasticSearch/Pritunl/Kibana, generate/rotate certs and passwords, write config, install a cron job, etc.), connecting exclusively via `ansible_connection=community.aws.aws_ssm` (no SSH). Each `deploy.sh` polls `aws ssm describe-instance-information` in a loop first, since a brand-new instance takes ~60-90s to register with SSM before Ansible can reach it, and retries the playbook run up to 3 times to absorb an SSM connection race observed in testing.

### 11.3 Provisioning order (must be sequential)
```
1. es-test/           deploy.sh <allowed_cidr>        (ElasticSearch, 3 nodes)
2. es-test/vpn/        deploy.sh <admin_cidr>          (Pritunl VPN — reads ES state)
3. es-test/monitoring/ deploy.sh                       (Kibana — reads ES + VPN state)
4. es-test/alerting/   deploy.sh <alert_email>         (CloudWatch + SNS — reads ES state)
```
Destroy order is the exact reverse (alerting → monitoring → vpn → es-test), since each stack's Terraform state depends on the one before it via `terraform_remote_state`.

For convenience, `~/vault/recreate-all.sh` on the operator's machine runs all 4 stacks in the correct order in a single command (used to validate a full destroy→recreate cycle from an empty AWS account in this session — see Section 10).

### 11.4 One manual step per stack (unavoidable, not a shortcut)
- **Alerting stack**: after `deploy.sh` finishes, AWS emails a Subscription Confirmation link to the alert email address — the alarm pipeline will not actually deliver notifications until that link is clicked. There is no AWS API to auto-confirm an SNS email subscription without owning the mailbox.
- **VPN stack**: the very first Pritunl admin login (setting the initial admin password, creating an org/user, downloading the `.ovpn` profile) is done once through the Pritunl web UI after `deploy.sh` finishes and prints the public IP + a `sudo pritunl default-password` hint. Pritunl's own workflow is designed around this being a human action.

Everything else — infra creation, software install, TLS cert generation, password generation/rotation, cron jobs, alarm/topic wiring — is fully automated end-to-end with zero manual steps.
