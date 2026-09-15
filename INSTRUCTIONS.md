# Infrastructure Engineer Take-Home — Secure ElasticSearch on AWS (Free Tier)

> DRAFT — brainstorm output, belum diimplementasikan/dites. Semua nilai cost adalah ASSUMPTION berbasis harga publik AWS us-east-1, bisa beda per region/waktu — cek AWS Pricing Calculator sebelum submit.

## 1. Ringkasan Solusi

Deploy 1x EC2 instance (t2.micro/t3.micro, free tier) menjalankan ElasticSearch single-node dengan:
- Autentikasi wajib (X-Pack Security)
- Komunikasi terenkripsi (TLS di HTTP layer 9200)
- Akses admin via AWS SSM Session Manager (tanpa port 22 terbuka)
- Security Group least-privilege (9200 hanya dari IP tertentu, bukan 0.0.0.0/0)

Provisioning: Terraform (infra) + user-data/Ansible (config ES).
Didesain **extensible ke 3-node cluster** — lihat Bagian 4.

## 2. Kenapa pilihan ini (jawaban pertanyaan take-home)

### Q1: Tool provisioning & bootstrapping — kenapa?
- **Terraform** untuk infra (VPC, SG, EC2, IAM role, EBS) — deklaratif, state-tracked, mudah destroy/recreate bersih (penting untuk exercise yang bakal di-cleanup setelah demo).
- **User-data script / Ansible** untuk install & config ES — idempotent, mudah dibaca reviewer, dan Ansible lebih natural untuk "config management" dibanding menaruh semuanya di Terraform provisioner.

### Q2: Cara mengamankan ElasticSearch — kenapa?
- `xpack.security.enabled: true` — built-in ES, tidak perlu proxy tambahan (mis. nginx basic-auth) yang justru nambah attack surface & maintenance.
- TLS self-signed via `elasticsearch-certutil` untuk HTTP layer — cukup untuk internal/demo; production sebaiknya certs dari CA terpercaya/ACM Private CA (ditulis sebagai catatan, bukan diimplementasikan — ASSUMPTION di luar scope free-tier exercise).
- Password built-in user (`elastic`) disimpan di **SSM Parameter Store SecureString** (KMS AWS-managed key), di-fetch instance via IAM role saat bootstrap — bukan hardcoded di script/repo (risk area: **secrets management**).
- Security Group membatasi akses port 9200 hanya dari IP pengetes (my-IP), bukan publik (risk area: **access control**).

### Q3: Monitoring — metric apa?
Lihat Bagian 3.

### Q4: Extend ke cluster 3-node aman — apa yang berubah?
Lihat Bagian 4.

### Q5: Replace node running tanpa/minim downtime
1. `PUT _cluster/settings {"transient":{"cluster.routing.allocation.enable":"none"}}` — freeze shard allocation.
2. Stop ES di node target, lakukan replace/patch/upgrade.
3. Start ES kembali, node rejoin cluster.
4. `PUT _cluster/settings {"transient":{"cluster.routing.allocation.enable":"all"}}`.
5. Tunggu `_cluster/health` kembali **green** sebelum lanjut ke node berikutnya (rolling, satu-satu, tidak paralel).

### Q6: Struktur kode rapi/extensible/reusable — prioritas?
Ya — Terraform dipisah per module (network, compute, security) dan pakai variable/count agar tinggal ubah `node_count` untuk scale 1→3 node, bukan copy-paste script.

### Q7: Trade-off karena keterbatasan resource (bukan waktu, tapi biaya free-tier)
- Implementasi **1-node** untuk demo real (agar $0 cost), 3-node didokumentasikan sebagai extension path — karena 3x EC2 24/7 + NAT Gateway di luar free tier (lihat tabel cost).
- Pakai **public subnet + SG ketat** alih-alih private subnet + NAT Gateway, karena NAT Gateway (~$32/bulan) adalah biaya terbesar yang bisa dihindari tanpa mengorbankan keamanan inti (TLS+auth tetap wajib, SG tetap restrict ke my-IP).
- Pakai AWS-managed KMS key (gratis) alih-alih customer-managed CMK ($1/bulan), karena kebutuhan audit granular per-key tidak proporsional untuk exercise ini.

## 3. Monitoring

| Layer | Metric | Alert threshold | Tool |
|---|---|---|---|
| Cluster | health status | != green | Metricbeat / `_cluster/health` |
| Cluster | unassigned shards | > 0 sustained | Metricbeat |
| Node | JVM heap usage | > 85% | Metricbeat / CloudWatch custom metric |
| Node | GC pause time | sustained > 1s | Metricbeat |
| Node | disk usage | > 85% (watermark) | CloudWatch Agent |
| Node | CPU / memory (host) | > 80% sustained | CloudWatch (basic, free) |
| Node | open file descriptors | near ulimit | Metricbeat |
| Query | search/index latency | baseline + 2x | Metricbeat / slow log |

- Dashboard: Kibana (bundled, no extra infra) sebagai default; CloudWatch dashboard untuk OS-level metric (gratis basic monitoring).
- Alerting: CloudWatch Alarm → SNS untuk threshold di atas (batasi ke metric kritis: heap%, disk%, cluster status — agar tetap dalam 10 custom metric gratis).
- Monitoring credential pakai role terbatas `remote_monitoring_collector`, bukan superuser `elastic`.

## 4. Extend ke 3-node cluster (secure)

- `discovery.seed_hosts` = 3 private IP node; semua node master-eligible + data (quorum otomatis butuh 2/3 vote, toleran 1 node down).
- Sebar node di ≥2 AZ berbeda untuk fault tolerance AZ-level.
- **Transport layer (9300) wajib TLS + mutual-auth** antar node — pakai node certs dari CA yang sama (bukan cuma HTTP layer seperti single-node).
- Security Group: 9300 inbound hanya dari SG-ES sendiri (self-referencing), tidak pernah publik.
- Terraform: ubah `aws_instance` jadi `count = 3` / `for_each` per subnet, tiap instance fetch cert unik dari CA yang disimpan di Secrets Manager/Parameter Store.

## 5. Cost Breakdown (Free Tier Reality Check)

| Komponen | Ideal best-practice | Est. cost/bulan | Keputusan diambil |
|---|---|---|---|
| EC2 (3 node) | Private subnet, 3 node HA | ~$15 (2 node bayar) | **1 node** untuk demo, dokumentasikan extension |
| NAT Gateway | Private subnet akses internet | ~$32 | **Public subnet + SG ketat** (no NAT) |
| Secrets Manager | Rotasi otomatis | ~$0.5 | **SSM Parameter Store SecureString** (gratis) |
| KMS CMK | Custom key, audit granular | ~$1 | **AWS-managed key** (gratis) |
| CloudWatch custom metrics | Full observability semua metric | bisa > free tier | Batasi ke 3-5 metric kritis (dalam 10 gratis) |
| EBS | gp3 per node | gratis ≤30GB total | Volume kecil (10-15GB/node) |

**Total estimasi implementasi actual (1-node, semua opsi hemat): $0/bulan** dalam window free-tier 12 bulan pertama.

## 6. Resources yang dikonsultasikan
- AWS Free Tier documentation — https://aws.amazon.com/free
- Elastic Security documentation (X-Pack Security, TLS setup) — https://www.elastic.co/guide/en/elasticsearch/reference/current/secure-cluster.html
- AWS Systems Manager Session Manager docs — https://docs.aws.amazon.com/systems-manager/

(ASSUMPTION: link di atas placeholder umum, ganti dengan sumber spesifik yang benar-benar dibaca saat pengerjaan.)

## 7. Waktu pengerjaan & feedback
(Isi setelah eksekusi — user diminta melaporkan waktu aktual & feedback jujur soal exercise.)
