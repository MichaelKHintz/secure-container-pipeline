Secure Container Pipeline on Amazon EKS

A container supply-chain lab: every change is scanned in GitHub Actions, images are pushed to Amazon ECR through a short-lived OIDC role and signed keyless with cosign, and an EKS cluster admits only images this pipeline signed. Falco and the EKS audit log watch the running workload.

Scope: personal lab, built in a dedicated AWS account (us-west-2) that is created and torn down with Terraform. It is not production, and the trade-offs I made for cost are listed below.

Results at a glance
Control	Result	Evidence
Image hardening	Baseline python:3.13: 4,152 OS and 6 Python findings. Hardened distroless image: 158 OS findings (26 HIGH, 0 CRITICAL, none with a fix available) and 0 Python findings	docs/evidence/trivy-baseline.txt, trivy-hardened.txt, trivy-hardened-gate.txt
Runtime user and shell	Runs as UID 65532; sh does not exist in the image	docs/evidence/hardened-user.txt, no-shell.txt
Dependency gate	PR #6 added PyYAML==5.3.1 (CVE-2020-14343, critical, fixed in 5.4). The sca job failed and the PR could not merge	docs/evidence/sca-gate-blocks-vulnerable-dep.txt
Automated updates gated too	PR #9, a Dependabot bump with mismatched pydantic and pydantic-core, failed its checks and was closed	PR history
Signing	Every main image is signed keyless; cosign verify ties the digest to ci.yml on main of this repo	Actions logs
Admission (Kyverno)	Signed app admitted; privileged, root, unsigned and signed-by-someone-else pods denied (1 allowed, 4 denied)	docs/evidence/kyverno-*.txt
Pod Security Admission	restricted denies a non-compliant pod in the app namespace	docs/evidence/psa-denied.txt
Network segmentation	Designated client reaches the app; any other client times out; the app has no egress	docs/evidence/netpol-*.txt
Runtime detection	See the Falco table below	docs/evidence/falco.log (redacted)
Architecture
PR
main
pass
yes
no
PR or push
Semgrep, Trivy fs, Checkov
Build and Trivy image scan
Build, push to ECR viaOIDC role
Trivy scan of pushed digest
cosign keyless sign andverify
Syft SBOM artifact
Digest committed todeploy branch
Flux in EKS pulls
PSA and Kyverno: signedby ci.yml on main?
Pod: non-root, read-only,default-deny network
Denied
Falco and EKS audit logs

Pull requests stop after the image scan, so nothing from an unmerged branch reaches ECR or gets signed. On main, the image is pushed, scanned again by digest, and only then signed. Kyverno fetches the signature from ECR through EKS Pod Identity at admission time, so an image that skipped a gate never gets a pod.

How it works
Pipeline (.github/workflows/ci.yml)
Job	Runs on	What it does	Fails when
sast	PRs and main	Semgrep (Python, security-audit, Dockerfile rules), SARIF to the Security tab	Any ERROR-severity finding
sca	PRs and main	Trivy filesystem scan of app/requirements.txt	Fixable HIGH or CRITICAL CVE
iac	PRs and main	Checkov on rendered Kubernetes manifests and on infra/ Terraform	Any failed check without a documented skip
image-pr	PRs only	Builds the image without pushing and scans it with Trivy	Fixable HIGH or CRITICAL CVE
publish	main only	OIDC role, push to ECR, Trivy scan of the pushed digest, cosign sign and verify, Syft SBOM	Any step fails
deploy	main only	Writes the signed digest into a rendered manifest on the deploy branch	Push fails, or a real registry URI leaks into the manifest

Pipeline hardening:

No stored cloud credentials. publish assumes an IAM role through GitHub OIDC. The trust policy matches the exact sub claim for main of this repo, using GitHub's immutable owner and repo IDs, and the role can write to one ECR repository only.
Least-privilege tokens. The workflow starts from permissions: {}, and each job asks only for what it needs.
Actions pinned to commit SHAs with pinact, kept current by Dependabot. The March 2026 trivy-action tag hijack is the reason.
Script-injection hygiene. Step outputs reach shell commands through env:, not inline expressions.
Cache poisoning guard. PRs read the build cache; only main writes it.
Account ID kept out of public output. It comes from a GitHub secret so logs mask it, the SBOM is redacted before upload, and manifests use an ${ECR_REGISTRY} placeholder that Flux fills in from a ConfigMap inside the cluster.
Branch rulesets. main requires a PR and the four check jobs; direct pushes are blocked.
Cluster (infra/cluster, EKS 1.35)
Control	Implementation
Network exposure	Private worker nodes, one NAT gateway, no load balancer or Ingress; EKS API limited to my IP
Cluster access	IAM access entries only (authentication_mode = "API"); I sign in through Okta and IAM Identity Center
Secrets at rest	Envelope encryption with a customer-managed KMS key (rotation on)
Control-plane logging	API, audit and authenticator logs to CloudWatch, 7-day retention
Node credentials	IMDSv2 required with a hop limit of 1, so pods cannot borrow the node role
Workload identity	Kyverno reads one ECR repository through EKS Pod Identity
Deployment	Flux pulls the deploy branch over public HTTPS; the pipeline never holds cluster credentials
Pod Security Admission	restricted enforced on the app namespace
Admission policies	Kyverno 1.19 CEL policies: disallow privileged, require non-root, require a signature from this repo's ci.yml on main
Network policy	VPC CNI enforcement; default deny in and out, one allowed client namespace and label
Service account	Dedicated account, no RoleBindings, token not mounted
Runtime detection	Falco (chart 9.2.0, modern_ebpf) with two custom rules
Runtime detection results

Two custom rules carry most of the signal: Unexpected process in secure-app (the app container should never start a second process) and Write below binary dir in workload container (a scoped version of an upstream rule that only ships in Falco's sandbox ruleset).

#	Action	Expected	Result
A1	kubectl exec ... sh into the hardened app	No alert; there is no shell, so no process starts
A2	python3 -c reads /etc/passwd in the app	Custom process rule fires
A3	python3 -c writes /usr/local/bin/x in the app	Process rule fires; the write fails on the read-only filesystem
B1	kubectl exec -it ... bash into a deliberately weak lab pod	Terminal shell in container
B2	cat /etc/shadow	Read sensitive file untrusted
B3	Read /etc/shadow with a bash builtin	Likely missed: the upstream rule excludes shell binaries
B4	Write /usr/local/bin/evil	Custom binary-directory rule
B5	Run a copied binary from /tmp	Drop and execute new binary in container

The hardened app shows prevention doing most of the work: no shell, a read-only root filesystem and no egress. The interpreter is still there, though, which is why the process-level rule matters. The EKS audit log records which IAM Identity Center session ran each kubectl exec, so an alert can be traced back to a person.

Challenges and what I learned

1. I created the first resources in the wrong AWS account. The foundation Terraform ran against my management account because my shell was using the wrong profile, and the first symptom was a 403 on the state bucket. I removed it properly (a versioned bucket needs every object version and delete marker deleted before the bucket can go) and rebuilt in the lab account. Since then I set AWS_PROFILE and run aws sts get-caller-identity before every apply. A dedicated account only isolates anything if you are actually in it.

2. Recreating the state bucket hung for about 11 minutes. S3 was still cleaning up the deleted bucket of the same name (OperationAborted: conflicting conditional operation), and there is no reliable signal for when that clears. A new name with an account-specific suffix fixed it immediately. I also moved the backend's bucket setting into a backend.hcl file so terraform init stops prompting for it.

3. Docker Hub rate limits broke CI. GitHub's shared runners hit 429s on anonymous Docker Hub pulls for the builder image, the Dockerfile frontend and BuildKit itself. Logging in with a read-only token was one option; I removed the dependency instead. The builder stage now comes from AWS's ECR Public mirror (I checked the Python and Debian versions and re-pinned the digest), the # syntax= line is gone, and BuildKit is pulled from ECR Public, pinned by digest. Registries are part of the supply chain for availability as well as integrity.

4. Checkov on Terraform: fix what is cheap, document the rest. The first run had 48 passes and 5 failures, all on the state bucket and KMS key. I fixed two: a lifecycle rule that expires old state versions after 90 days, and an explicit key policy. I skipped three with written reasons: access logging, cross-region replication and event notifications. Fully satisfying them would have added more buckets that fail the same checks. A documented risk acceptance is a legitimate result.

5. Typos passed every scanner and failed at deploy. A Service with ports nested under selector, a ServiceAccount name that did not match the Deployment, a misspelled metadata key, and the wrong GitHub username in the Flux source all looked fine to Checkov, which checks policy, not schema. Each fix had to go through a PR, the pipeline and the deploy branch, because Flux only applies what the pipeline renders. The lesson is a missing gate: schema validation (kubeconform or a server-side dry run) belongs in the iac job.

6. Dependabot opened a PR that could not build. It bumped pydantic without the matching pydantic-core. The PR checks failed, so it never merged. I grouped the pydantic packages in dependabot.yml and regenerated the pins. Automated changes need the same gates as human ones.

7. "Zero CVEs" was the wrong goal. The hardened image still reports 158 OS-level findings, all in Debian packages with no fix available (26 HIGH, 0 CRITICAL). The gate fails only on fixable HIGH or CRITICAL findings, and the remaining risk is reduced by the image having no shell and no package manager. I chose that over an ignore file with 158 entries.

8. Proving why Kyverno denied something. The unsigned pod and the signed-by-someone-else pod both return the same policy message, so the output alone does not show which check failed. The admission controller's logs do. On rebuilds, Kyverno has to be installed before Flux deploys the app, because the signature policy fails closed.

9. Making sure Falco saw everything. Falco 0.45 does not log the container runtime socket at startup, so I confirmed pod metadata through the DaemonSet's host mounts and the fields in real alerts. kubectl logs ds/falco reads only one pod, which would have hidden alerts from the second node, so I stream logs by label across all Falco pods.

10. Working habits. Partway through I moved from committing to main to a branch and PR for every change, enforced by a ruleset with required checks. The EKS cluster bills by the hour, so it is destroyed at the end of every session, and debugging time has a visible cost.

Design decisions and trade-offs
EKS instead of k3s on one EC2 instance: a managed control plane, Pod Identity, access entries and audit logs, at $0.10 an hour for the control plane. I accepted that by rebuilding per session.
Keyless signing instead of KMS-held signing keys: no key to store or rotate, and the identity is the repo, workflow and branch. The trade-off is reliance on public Sigstore services.
Pull-based GitOps instead of pushing from CI: the pipeline never needs cluster credentials, and the API is never opened to GitHub.
Kyverno CEL policy types instead of Gatekeeper: native image verification, and ClusterPolicy is being removed in Kyverno 1.20.
Cost-driven choices: one NAT gateway and a public API endpoint limited to one IP, instead of per-AZ NAT and a private endpoint.
Cost and teardown

About $0.24 an hour while the cluster exists (control plane, two t3.medium nodes, NAT gateway). A $25 monthly AWS Budget alerts at 50% of actual and 100% of forecast spend. Total spend for the project: $0.56
Each session: terraform apply in infra/cluster, then scripts/bootstrap-cluster.sh, then terraform destroy at the end.
Final teardown: destroy infra/foundation (ECR, push role, OIDC provider, KMS key scheduled for deletion), remove the GitHub secrets, then empty the state bucket and destroy infra/bootstrap.
What I would change in production
Add schema validation of manifests to the iac job (lesson 5)
Private EKS endpoint reached over VPN or SSM, and VPC endpoints for ECR, S3 and STS in place of internet egress
A NAT gateway per availability zone
Policies rolled out in Audit before Deny, with time-boxed exceptions
GuardDuty EKS protection alongside Falco, with alerts routed to a SIEM
Network policy strict mode, and SBOM attestations verified at admission
How it maps to PCI DSS v4.0.1

Closest-fit mapping, for discussion; not an assessment.

Control here	Requirement
SBOM per image digest	6.3.2, inventory of software components
Trivy gates, ECR scan on push, Dependabot	6.3.1 and 6.3.3, identify vulnerabilities and apply patches
Semgrep on every PR	6.2.3 and 6.2.4, code review and prevention of common attacks
PSA, Kyverno, Checkov	2.2, secure configuration standards
Default-deny network policy, private nodes, API allowlist	1.3 and 1.4, restrict traffic
Non-root pods, permissionless service account, one-repo IAM roles, IMDS hop limit	7.2, least privilege
Okta and Identity Center sign-in with MFA, EKS access entries	8.2 and 8.4, unique identities and MFA
Only pipeline-signed images admitted	6.5.1, change control
EKS audit logs, Falco	10.2 audit logs and 11.5.1 intrusion detection
Repository layout
text
app/                 FastAPI app and pinned requirements
baseline/            the intentionally weak "before" image
Dockerfile           hardened distroless image
.github/workflows/   ci.yml
infra/bootstrap/     state bucket and budget
infra/foundation/    KMS key, ECR repository, GitHub OIDC push role
infra/cluster/       VPC, EKS, add-ons, Kyverno's Pod Identity role
k8s/                 app manifests (Kustomize)
clusters/aws/        Flux source and Kustomization
policies/kyverno/    admission policies
falco/               Helm values and custom rules
tests/               pods used to prove the policies and detections
scripts/             cluster bootstrap and evidence redaction
docs/evidence/       redacted outputs
Reproduce it

Prerequisites: an AWS account you can sign in to through IAM Identity Center, Terraform 1.10 or newer, Docker, kubectl, helm and the Flux CLI.

bash
export AWS_PROFILE=<your-profile>
aws sts get-caller-identity                       # confirm the account first

terraform -chdir=infra/bootstrap apply            # state bucket and budget
terraform -chdir=infra/foundation init -backend-config=backend.hcl
terraform -chdir=infra/foundation apply           # KMS, ECR, OIDC push role
# add AWS_ACCOUNT_ID and AWS_PUSH_ROLE_ARN as GitHub secrets, then merge to main

MYIP="$(curl -s https://checkip.amazonaws.com)/32"
terraform -chdir=infra/cluster init -backend-config=backend.hcl
terraform -chdir=infra/cluster apply -var "my_ip_cidr=$MYIP"
./scripts/bootstrap-cluster.sh                    # Kyverno, Flux, Falco

terraform -chdir=infra/cluster destroy -var "my_ip_cidr=$MYIP"   # every session
