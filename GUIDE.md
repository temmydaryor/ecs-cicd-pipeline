# Project 3 — Containerized CI/CD Pipeline (GitHub Actions → ECR → ECS Fargate)

A complete, click-by-click and command-by-command guide, written for **Windows + PowerShell**, region **ca-west-1 (Calgary)**.
Every phase lists the exact commands, what you should see, the hidden details that usually break people, and what to screenshot.

> **Read this first — what has and has not been tested**
> - Tested here: the 4 unit tests pass; the workflow YAML and every Terraform file parse correctly.
> - **Not** tested here (no Docker daemon, no Terraform binary, no AWS or GitHub access in my sandbox): `docker build`, `terraform validate/apply`, the PowerShell scripts, and a live pipeline run.
> - So expect to hit one or two small errors on your first run. That is normal and is good interview material. Paste the error to me and I will fix it. Where I am unsure of a detail, I say so.
> - Fargate **is** supported in ca-west-1 (checked against the AWS docs page for supported Fargate Regions).

---

## 0. What you are building

```
  git push (main)
       │
       ▼
┌─────────────────────────── GitHub Actions ───────────────────────────┐
│  test job            build-push job              deploy job          │
│  pytest + hadolint   docker build → ECR push     ⏸ manual approval   │
│  docker build check  ECR vulnerability scan      render task def     │
│  (every push + PR)   (OIDC "build" role)         ECS rolling deploy  │
│                                                  smoke test          │
│                                                  auto-rollback       │
└──────────────────────────────────────────────────(OIDC "deploy" role)┘
                          │
                          ▼
   Internet → ALB (port 80) → ECS Fargate tasks (2×, port 8080) → CloudWatch Logs
                                     │
              CloudWatch alarms (unhealthy hosts, 5xx) → SNS email
              + ECS deployment circuit breaker + alarm-based rollback
```

**Your 7 requested deliverables → where they live**

| # | Requirement | Where it is implemented |
|---|---|---|
| 1 | Multi-stage Dockerfile, small image | `Dockerfile` (Phase 1) |
| 2 | Manual first push to ECR | `scripts/push-first-image.ps1` (Phase 2) |
| 3 | GitHub Actions: test → build → push → deploy | `.github/workflows/deploy.yml` (Phases 5–6) |
| 4 | Approval gate / zero-downtime | GitHub Environment `production` + rolling deploy at 100%/200% (Phases 5, 7) |
| 5 | Rollback | Circuit breaker + alarms + smoke-test rollback + manual `rollback.yml` (Phase 8) |
| 6 | CloudWatch Logs/Alarms | `infra/monitoring.tf` (Phase 9) |
| 7 | Before/after deploy time | `scripts/manual-deploy.ps1` + `docs/metrics.md` (Phases 4, 10) |

**Time:** about 4–6 hours the first time (the Terraform apply and the ECS waits are the slow parts).
**Cost while running:** roughly **$1.50–2.50 per day** (ALB + 2 small Fargate tasks + public IPv4 addresses + logs). These are my estimates, not exact — check the AWS Pricing Calculator. **Run `terraform destroy` when you are not demoing** (Phase 11).

**Design choices I made, and why (all are interview talking points)**

| Choice | Why |
|---|---|
| Default VPC, tasks get public IPs, **no NAT Gateway** | A NAT Gateway costs about $33+/month. The tasks are still only reachable from the ALB because the task security group only allows the ALB's security group. |
| Rolling deploy + approval gate as the main path; native blue/green as an optional upgrade | Simplest thing that gives zero downtime and rollback. ECS now has built-in blue/green (no CodeDeploy needed) — see Phase 7. |
| OIDC, **two** IAM roles (build vs deploy) | No long-lived AWS keys in GitHub. Build role can only push to one ECR repo. Deploy role can only update one ECS service. |
| Image tag = git SHA, ECR tags **immutable** | Every running container is traceable to one commit. Rollback targets are guaranteed unchanged. |
| Pipeline downloads the *live* task definition and only swaps the image | No account IDs hard-coded in the repo and no drift. Trade-off in Phase 12. |

---

## 1. Phase 0 — Prerequisites and Windows setup (30–45 min)

### 1.1 Install / verify tools

Open **Windows PowerShell** (or PowerShell 7) and run each line. All must print a version.

```powershell
git --version
aws --version          # must be AWS CLI v2 (aws-cli/2.x)
terraform version      # you have 1.16.0; this project needs >= 1.10
docker --version
gh --version           # GitHub CLI; install: winget install GitHub.cli
python --version       # 3.12 recommended (only needed to run the tests locally)
```

Missing something? (run PowerShell **as Administrator** for winget installs)

```powershell
winget install Git.Git
winget install Amazon.AWSCLI
winget install Docker.DockerDesktop
winget install GitHub.cli
winget install Python.Python.3.12
```

**Hidden details**
- **Docker Desktop must be running** (whale icon in the system tray, "Engine running"). The errors `error during connect` / `cannot connect to the Docker daemon` just mean it is not started.
- Docker Desktop on Windows should use the **WSL 2 backend** (Settings → General → "Use the WSL 2 based engine"). If WSL is not installed: `wsl --install`, then reboot.
- Stop AWS CLI output from opening a pager that hangs your terminal:
  ```powershell
  $env:AWS_PAGER = ""
  ```
- Make the region sticky so you do not have to type it everywhere (it must be `ca-west-1`):
  ```powershell
  aws configure set region ca-west-1
  $env:AWS_REGION = "ca-west-1"
  ```

### 1.2 Confirm your AWS credentials work (you hit `InvalidClientTokenId` earlier — do this first)

```powershell
aws sts get-caller-identity
```
You should see your `Account`, `UserId` and `Arn`. If you get `InvalidClientTokenId`, fix credentials **now** (re-run `aws configure`, or `aws sso login`, and clear stale `$env:AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `AWS_SESSION_TOKEN` variables as we discussed). Nothing else in this guide works until this command succeeds.

Your IAM user needs permission to create ECR, ECS, ELB, IAM roles/OIDC providers, CloudWatch, SNS and EventBridge resources. For a personal learning account, `AdministratorAccess` on a dedicated IAM user is the pragmatic choice. **Never use the root user.**

### 1.3 Git line endings (Windows-specific)

```powershell
git config --global core.autocrlf input
git config --global init.defaultBranch main
git config --global user.name  "Your Name"
git config --global user.email "you@example.com"
```
The project includes a `.gitattributes` that forces LF line endings. CRLF inside a `Dockerfile` or workflow can cause confusing failures on Linux.

### 1.4 GitHub login

```powershell
gh auth login      # choose GitHub.com → HTTPS → Login with a web browser
gh auth status
```

### 1.5 Put the project in a folder

Unzip the project somewhere **short and without spaces** (not inside your long "AWS Certified Solution Architect Associate" folder path — long paths and spaces cause avoidable pain):

```powershell
cd C:\dev\ecs-cicd-pipeline
dir
```
You should see: `Dockerfile`, `webapp`, `tests`, `infra`, `scripts`, `.github`, `GUIDE.md`.

---

## 2. Phase 1 — Run the app and tests locally, then build the image (30 min)

### 2.1 Understand the app (2 minutes)

`webapp/app.py` is a tiny Flask service:
- `GET /` → JSON with `version` (the git SHA), hostname, uptime
- `GET /health` → `200 {"status":"ok"}` — used by Docker, ECS and the ALB
- Setting the env var `FORCE_UNHEALTHY=true` makes `/health` return 500 (not used by the pipeline; handy for experiments)

The `version` field is what lets you **prove** a deploy happened and which commit is live.

### 2.2 Run the unit tests

```powershell
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements-dev.txt
pytest -q
```
Expected: `4 passed`.

> If `Activate.ps1` is blocked: `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`, answer `Y`, and retry.

### 2.3 Build the image and run it

```powershell
docker build --build-arg GIT_SHA=local1 -t ecs-demo:local .
docker run --rm -d -p 8080:8080 --name ecs-demo ecs-demo:local
Start-Sleep 3
curl.exe -s http://localhost:8080/health
curl.exe -s http://localhost:8080/
docker ps --format "table {{.Names}}\t{{.Status}}"
```
Use `curl.exe` (with the `.exe`) — plain `curl` in Windows PowerShell 5.1 is an alias for `Invoke-WebRequest` and prints a different format.

After ~15–30 seconds `docker ps` should show `(healthy)` — that is the Dockerfile `HEALTHCHECK` working. Stop it: `docker stop ecs-demo`.

### 2.4 Why the Dockerfile looks the way it does (interview answers)

| Line | Reason |
|---|---|
| `FROM python:3.12-slim AS builder` / `AS runtime` | **Multi-stage**: pip and any build tooling stay in stage 1. Only the installed packages are copied into the final image, so it is smaller and has a smaller attack surface. |
| `pip install --prefix=/install` then `COPY --from=builder /install /usr/local` | The clean hand-off between stages. |
| `useradd --system --uid 10001` + `USER 10001` | Runs as **non-root**. A numeric UID lets policy tools verify it. |
| `HEALTHCHECK … python -c "urllib…"` | `python:slim` has **no curl or wget**, so a `curl` health check would silently always fail. |
| `ARG GIT_SHA` → `ENV GIT_SHA` | Bakes the commit into the image so `GET /` reports exactly what is running. |
| `PYTHONUNBUFFERED=1` | Logs appear in CloudWatch immediately instead of being buffered. |
| `gunicorn` (not `flask run`) | The Flask dev server is not for production. |
| `.dockerignore` | Keeps `.git`, `infra`, tests, and Terraform state out of the build context (smaller, faster, and no secrets leaking into layers). |

### 2.5 Measure image size — your interview number (do this now)

```powershell
docker image ls ecs-demo:local --format "multi-stage slim: {{.Size}}"
```

Now build a deliberately bad version to compare (a single-stage image on the full Python base). Create a temporary file `Dockerfile.bad`:

```powershell
@"
FROM python:3.12
WORKDIR /app
COPY webapp/ .
RUN pip install -r requirements.txt
CMD ["gunicorn","--bind","0.0.0.0:8080","app:app"]
"@ | Set-Content -Encoding ascii Dockerfile.bad
docker build -f Dockerfile.bad -t ecs-demo:bad .
docker image ls ecs-demo --format "{{.Tag}}: {{.Size}}"
Remove-Item Dockerfile.bad
```
Record both sizes in `docs/metrics.md`. (I have not measured these myself — the full `python:3.12` image is typically several times larger than `-slim`, but write down **your** numbers.) Optional: `docker history ecs-demo:local` shows what each layer costs.

📸 **Screenshot 1:** `docker image ls` showing both sizes.

---

## 3. Phase 2 — Create the ECR repository and push the first image manually (30 min) — requirement #2

Goal: prove the deployment target works **before** any automation exists. This also solves a chicken-and-egg problem: an ECS service cannot start unless the image it references already exists.

### 3.1 Prepare Terraform variables

```powershell
cd infra
Copy-Item terraform.tfvars.example terraform.tfvars
notepad terraform.tfvars
```
Set:
- `github_org` — your GitHub username, **exactly** as GitHub shows it (case-sensitive; the OIDC trust policy compares it literally)
- `github_repo` — `ecs-cicd-pipeline` (or whatever you will name the repo)
- `alert_email` — an inbox you can open
- `create_oidc_provider` — check first:
  ```powershell
  aws iam list-open-id-connect-providers
  ```
  If you see `token.actions.githubusercontent.com` in the output, set `create_oidc_provider = false` (AWS allows only **one** per account; creating a second fails with `EntityAlreadyExists`).

### 3.2 Create only the ECR repository

```powershell
terraform init
terraform apply -target='aws_ecr_repository.app'
```
Type `yes`. (Using `-target` is normally discouraged; here it is the clean way to do a staged bootstrap. Terraform will warn you — that is expected.)

### 3.3 Build and push the first image

Go back to the project root and run the helper:

```powershell
cd ..
.\scripts\push-first-image.ps1
```
It builds with `--platform linux/amd64`, logs in to ECR, pushes `manual-v1`, and prints sizes.

If PowerShell refuses to run the script: `powershell -ExecutionPolicy Bypass -File .\scripts\push-first-image.ps1`

**Manual equivalent (so you understand each step):**
```powershell
$ACCOUNT  = aws sts get-caller-identity --query Account --output text
$REGISTRY = "$ACCOUNT.dkr.ecr.ca-west-1.amazonaws.com"
$pw = (aws ecr get-login-password --region ca-west-1 | Out-String).Trim()
docker login --username AWS --password $pw $REGISTRY
docker build --platform linux/amd64 --build-arg GIT_SHA=manual-v1 -t "$REGISTRY/ecs-cicd-app:manual-v1" .
docker push "$REGISTRY/ecs-cicd-app:manual-v1"
```

**Hidden details**
- The ECR login token is valid for **12 hours**. `no basic auth credentials` = log in again.
- `--platform linux/amd64`: the ECS task definition in this project is `X86_64`. If you ever build on an ARM machine (Apple Silicon, Windows on ARM) and skip this flag, the container crashes at start with **`exec format error`** in the CloudWatch logs.
- The repository is **immutable-tagged**: you can push `manual-v1` exactly once. A second push of the same tag fails with `tag invalid: The image tag 'manual-v1' already exists`. That is a feature (traceability), and it is why this pipeline never uses `:latest`.

### 3.4 Verify in the console

1. AWS Console → top-right region selector → **Canada West (Calgary) ca-west-1**
2. Search **ECR** → left menu **Private registry → Repositories** → **ecs-cicd-app**
3. You should see tag `manual-v1`, its size, and (after about a minute) a vulnerability scan result in the **Vulnerabilities** column.

📸 **Screenshot 2:** the ECR repository showing `manual-v1` and its scan result.

---

## 4. Phase 3 — Create everything else with Terraform (20 min, mostly waiting)

```powershell
cd infra
terraform plan
terraform apply
```
Review the plan (roughly 35–40 resources). Type `yes`. It takes about 3–6 minutes.

What gets created: security groups, ALB + target group + listener, ECS cluster, log group, two task IAM roles, the task definition (using `manual-v1`), the ECS service (2 tasks), two GitHub OIDC IAM roles, SNS topic + email subscription, two CloudWatch alarms, and an EventBridge rule.

### 4.1 Immediately do these two things

1. **Open your email and click "Confirm subscription"** in the AWS Notifications message. **Until you click it, no alarm email will ever arrive.** (Check spam; it comes from `no-reply@sns.amazonaws.com`.)
2. Save the outputs:
   ```powershell
   terraform output
   terraform output -raw alb_url
   ```

### 4.2 Verify it is alive (give it 2–3 minutes after apply)

```powershell
$URL = terraform output -raw alb_url
curl.exe -s "$URL/health"
curl.exe -s "$URL/"
```
Expected: `{"status":"ok","version":"manual-v1"}`.

**Click through the console to see each piece:**
- **ECS** → Clusters → `ecs-cicd-cluster` → Services → `ecs-cicd-service` → tabs **Tasks** (2 running), **Deployments**, **Logs**, **Health and metrics**
- **EC2** → Load Balancing → **Target Groups** → `ecs-cicd-tg` → **Targets**: both `healthy`
- **CloudWatch** → Logs → Log groups → `/ecs/ecs-cicd` → open a stream and see gunicorn access logs
- **CloudWatch** → Alarms → both alarms should be `OK` (or `Insufficient data` for the first minutes)

📸 **Screenshots 3–5:** ECS service Tasks tab (2 running), target group (2 healthy), browser showing the JSON from the ALB URL.

### 4.3 If something is wrong (most common first)

| Symptom | Cause | Fix |
|---|---|---|
| ALB URL returns **503** | No healthy targets yet | Wait 2–3 min; check Target Group → Targets and the ECS service **Events** tab |
| Task stops with `CannotPullContainerError … i/o timeout` | Task cannot reach ECR | Tasks need a public IP (set in `ecs.tf`) or NAT/VPC endpoints. Confirm `assign_public_ip = true` and that you did not change the default VPC's route to the internet |
| `CannotPullContainerError … not found` | Tag does not exist | `aws ecr describe-images --repository-name ecs-cicd-app` and compare to `image_tag` in tfvars |
| Logs show `exec format error` | Built for wrong CPU architecture | Rebuild with `--platform linux/amd64` and push a new tag |
| Tasks keep restarting, target `unhealthy` | `/health` unreachable or wrong port | `aws logs tail /ecs/ecs-cicd --since 15m`; the app must listen on **8080** on `0.0.0.0` |
| `Error: Invalid index` / `slice` error in `network.tf` | Default VPC missing or has < 2 subnets | `aws ec2 create-default-vpc` |
| `EntityAlreadyExists` on the OIDC provider | One already exists in the account | Set `create_oidc_provider = false` and re-apply |
| `AccessDenied` creating roles | Your IAM user lacks permissions | Use an admin-capable IAM user (not root) |

---

## 5. Phase 4 — Record the BEFORE metric: a manual deploy (45 min) — requirement #7

You need an honest "before". Do the manual deployment **three times** and keep the median.

### 5.1 Make a visible change

In `webapp/app.py`, change the `service="ecs-cicd-demo"` text to `service="ecs-cicd-demo-v2"`. Do **not** commit anything yet (the pipeline does not exist). Run the tests (`pytest -q` — update the assertion in `tests/test_app.py` to match the new name).

### 5.2 Deploy by script and read the timings

```powershell
.\scripts\manual-deploy.ps1 -Tag manual-v2
```
It prints per-phase times: docker build, ECR login+push, register task definition, update service + wait for stable. For the next runs use `manual-v3`, `manual-v4` (tags are immutable — each run needs a new one).

### 5.3 Deploy once fully by hand in the console (for your own "manual pain" count)

1. Push a new image by hand: run the "Manual equivalent" commands from Phase 2 (account/registry variables, `docker login`, `docker build`, `docker push`) with a **new** tag such as `manual-v5` (tags are immutable)
2. **ECS → Task definitions → `ecs-cicd-app` → Create new revision**
3. Scroll to **Container - 1 → Image URI** → paste the new image URI → **Create**
4. **ECS → Clusters → `ecs-cicd-cluster` → Services → `ecs-cicd-service` → Update service**
5. **Revision** dropdown → pick the newest → **Update**
6. Watch the **Deployments** tab until status is **Completed**
7. Hit the ALB URL and confirm the new version

Count the steps and time yourself with a stopwatch. Add the time you spent clicking and copy-pasting to the machine time. That total is your realistic "manual deploy" number.

### 5.4 Record it

Fill in the first table in `docs/metrics.md`. Typical shape of a result: a few minutes of machine time plus hands-on overhead — but **use your measured values**.

---

## 6. Phase 5 — Put the code on GitHub and wire up the pipeline (30 min) — requirements #3 and #4

### 6.1 Create the repo and push

Your `github_org` / `github_repo` Terraform variables (Phase 3) **must exactly match** the GitHub owner and repo name, including capitalisation — the OIDC trust policy compares them as strings. If they do not match, the pipeline fails later with `Not authorized to perform sts:AssumeRoleWithWebIdentity`.

```powershell
git init -b main            # skip if already done in Phase 0
git add .
git status                  # read this list! no *.tfstate, *.tfvars, .env, .terraform/
git commit -m "Initial commit: app, Dockerfile, Terraform, workflows"
gh auth status
gh repo create ecs-cicd-pipeline --public --source . --remote origin --push
```

**Public vs private:** use **public** unless you have a reason not to. Environment "Required reviewers" (the approval gate) is available on public repos for every plan, but on **private repos only on paid plans**. On a private Free-plan repo the environment is created but the approval is silently not enforced, and your "manual approval gate" claim would be false.

Look at the Actions tab right now. The push you just made triggers the workflow. It will:
- run the `test` job (should pass — it needs no AWS), and
- fail or stall at `build-push` because the repository variables are not set yet.

That is expected. Cancel the run if you like.


> **Hidden detail — immutable OIDC subject (new GitHub repos).** Run `gh api repos/YOU/ecs-cicd-pipeline/actions/oidc/customization/sub`. If it shows `"use_immutable_subject": true` and a `sub_claim_prefix` such as `repo:YOU@123/ecs-cicd-pipeline@456`, put that exact prefix in `github_sub_prefix` in `terraform.tfvars` and apply. Otherwise the roles only trust the name-based subject and the pipeline fails with `Not authorized to perform sts:AssumeRoleWithWebIdentity`.

### 6.2 Set the repository variables

```powershell
.\scripts\set-github-vars.ps1 -GitHubRepo "YOUR_GITHUB_USER/ecs-cicd-pipeline"
gh variable list --repo YOUR_GITHUB_USER/ecs-cicd-pipeline
```
You should see 8 variables. They are **variables, not secrets**: role ARNs and names are not sensitive, and there are **no AWS access keys anywhere** — that is the point of OIDC.

If `gh variable set` fails with HTTP 403/404, run `gh auth refresh -s repo` and retry.

### 6.3 Create the `production` environment with the approval gate

Do this in the browser:

1. GitHub repo → **Settings** → **Environments** → **New environment**
2. Name: `production` (exactly — the deploy role's trust policy and `deploy.yml` both say `production`) → **Configure environment**
3. Tick **Required reviewers** → search for and select **your own user** → **Save protection rules**
4. **Leave "Prevent self-review" UNCHECKED.** You are the only person in the repo; if it is on, nobody can approve your deployments and every run hangs forever.
5. **Deployment branches and tags** → choose **Selected branches and tags** → **Add deployment branch rule** → `main`. This stops a feature branch from deploying to production.
6. Do **not** add environment secrets; none are needed.

Hidden detail: if the environment does not exist when the workflow first runs, GitHub auto-creates it **with no protection**, and the deploy job runs unattended. Always create it before the first run.

### 6.4 Optional: protect `main`

Settings → **Rules → Rulesets** (or Branches → Add rule) for `main`: require status check `test`, block force-pushes. As a solo dev do **not** require pull-request reviews, or you cannot merge your own work. This is a nice interview talking point but not required.

---

## 7. Phase 6 — First pipeline run, end to end (30 min)

### 7.1 Trigger it

Make a tiny, safe change (for example the version text in a comment in `app.py`) and push:

```powershell
git add -A
git commit -m "Trigger first pipeline run"
git push
```
Note: changes only to `docs/`, `infra/`, or `*.md` are deliberately ignored by the push trigger (`paths-ignore`). A README edit will **not** deploy — use a file under `webapp/` or the `Dockerfile`.

### 7.2 What you should see (Actions tab → run "ci-cd")

| Job | What happens | Typical duration |
|---|---|---|
| `test` | pytest, hadolint, test-only docker build | 1–2 min |
| `build-push` | OIDC login, docker build, push tag = first 7 chars of commit SHA, ECR scan check | 1–3 min |
| `deploy` | **Waiting** — yellow banner "Review pending deployments" | until you click |

4. Click the run → **Review deployments** → tick `production` → (optional comment) → **Approve and deploy**.
5. The deploy job then downloads the live task definition, swaps in the new image, updates the service, waits for stability, smoke-tests `APP_URL`, and writes the timing to the **job summary**.

Open the job summary (bottom of the run page) and copy the deploy-duration line into `docs/metrics.md`.

### 7.3 Confirm in AWS

```powershell
$env:AWS_PAGER = ""
curl.exe -s $(terraform -chdir=infra output -raw alb_url)
aws ecs describe-services --cluster ecs-cicd-cluster --services ecs-cicd-service --region ca-west-1 `
  --query "services[0].{taskDef:taskDefinition,running:runningCount,desired:desiredCount,deployments:deployments[].{status:status,rollout:rolloutState}}"
```
`version` in the JSON must equal the 7-character SHA of your commit. ECR → repository should now contain `manual-v1`, `manual-v2`..., plus the SHA tag.

### 7.4 If the first run fails — most common causes

| Symptom | Cause | Fix |
|---|---|---|
| `Not authorized to perform sts:AssumeRoleWithWebIdentity` | `github_org`/`github_repo` mismatch, or job runs from a branch/environment the trust policy does not allow | Fix tfvars → `terraform apply`. Build role = `main` branch only; deploy role = `production` environment only |
| `Credentials could not be loaded` | Missing `permissions: id-token: write` or empty `AWS_*_ROLE_ARN` variable | Re-run `set-github-vars.ps1` |
| `OIDC provider already exists` during Phase 3 | Provider is one-per-account; Project 2/other work created it | Set `create_oidc_provider = false` in tfvars and re-apply |
| `ImmutableTagsException` / tag already exists | You re-ran a job for a commit already pushed | Re-run only the failed job downstream, or push a new commit |
| `exec format error` in ECS logs | Image built for ARM (Apple/Windows-on-ARM) but task is X86_64 | The workflow/scripts use `--platform linux/amd64`; keep that |
| Deploy job hangs on "Waiting" forever | Self-review prevention on, or you are not the reviewer, or private-repo plan | See 6.3 |
| Smoke test fails but service looks fine | `APP_URL` has trailing slash/typo or ALB still registering | Check variable; the job retries 20 times |
| Task stops with `CannotPullContainerError` | Tasks in a public subnet need `assign_public_ip = true` (set) and the SG allows outbound | Check ECS service networking |

---

## 8. Phase 7 — Prove zero-downtime deploys (20 min)

### 8.1 Why this works (know this for interviews)

The service uses `minimum_healthy_percent = 100` and `maximum_percent = 200`. ECS starts the **new** tasks first (up to double the count), waits for them to pass the ALB health check, and only then stops the old ones. The target group `deregistration_delay = 30` gives in-flight requests 30 s to finish (the AWS default of 300 s makes every deploy ~5 minutes slower).

### 8.2 Run a request loop during a deploy

Open a second PowerShell window **before** approving a deploy:

```powershell
$url = terraform -chdir=infra output -raw alb_url
$ok = 0; $fail = 0; $versions = @{}
1..600 | ForEach-Object {
  try {
    $r = Invoke-RestMethod -Uri $url -TimeoutSec 3
    $ok++; $versions[$r.version] = 1 + [int]$versions[$r.version]
  } catch { $fail++ }
  Start-Sleep -Milliseconds 500
}
"ok=$ok fail=$fail"; $versions
```
Push a change, approve it, and let the loop run through the cut-over. You should see both old and new versions, and `fail=0` (occasional single failures can happen; report what you actually observe — don't claim "zero" unless you saw zero).

### 8.3 Optional upgrade: ECS native blue/green

ECS added built-in blue/green deployments (no CodeDeploy needed) in 2025: a second target group, a test listener, a bake time, and lifecycle hooks. It doubles tasks during a deploy. **This project does not include or test Terraform for it.** The rolling deployment + circuit breaker + approval gate already satisfies requirement #4 ("manual approval gate **or** blue/green"). If you add blue/green later, say so honestly as a follow-up.

---

## 9. Phase 8 — Rollback (45 min) — requirement #5

You have four layers. Demonstrate at least 1 and 2 and screenshot them.

| Layer | Trigger | Where |
|---|---|---|
| 0. CI gate | Failing test or Dockerfile lint | `test` job stops the pipeline before anything reaches AWS |
| 1. ECS circuit breaker | New tasks keep failing to start / pass health check | ECS service setting `deployment_circuit_breaker { rollback = true }` |
| 2. CloudWatch alarm rollback | `unhealthy-hosts` or `target-5xx` alarm fires during a deploy | ECS service `alarms` block |
| 3. Workflow smoke-test rollback | Service "stable" but `/` doesn't serve the new SHA | `if: failure()` step in `deploy` job |
| 4. Manual | You decide | `rollback.yml` workflow or `scripts/rollback.ps1` |

### 9.1 Demo A — CI gate blocks a bad change

1. Edit `tests/test_app.py` so an assertion is wrong → commit → push.
2. `test` job turns red; `build-push` and `deploy` never start. Screenshot it.
3. `git revert HEAD` → push (or fix the test).

### 9.2 Demo B — a bad release that passes tests but is unhealthy in ECS

1. In `Dockerfile`, change `--bind 0.0.0.0:8080` to `--bind 0.0.0.0:9090` (the container now listens on the wrong port). Unit tests and the build still pass.
2. Commit, push, approve the deployment.
3. Watch **ECS → cluster → service → Deployments** and **Events**: new tasks start, fail the health check, ECS stops them, and the deployment shows **Rolled back** while the old version keeps serving traffic. Screenshot the Events tab with timestamps.
4. The GitHub deploy job turns red (the service did not reach the new version). The EventBridge rule sends you an SNS email about the failed deployment.
5. Note the time between the deploy starting and "rolled back" — that is your "Z" for the resume bullet. It depends on the health-check grace period and the circuit breaker threshold; measure, don't guess.
6. Clean up: `git revert HEAD` → push → approve → confirm the good version deploys again.

### 9.3 Demo C — manual rollback

GitHub → Actions → **rollback** → **Run workflow** → leave `revision` blank (previous revision) or enter a number → approve in `production`. Or from your laptop:

```powershell
.\scripts\rollback.ps1              # previous ACTIVE revision
.\scripts\rollback.ps1 -Revision 7  # a specific one
```

### 9.4 Hidden details about rollback

- Rollback re-deploys an **old task definition revision**, which points to an **old image**. The image must still be in ECR. The lifecycle policy keeps the last 15 images — keep that number above how far back you would ever roll.
- After a rollback, the running service is on an older revision than `main`. The next push to `main` deploys forward again. Fix the bad commit with `git revert`, don't leave `main` broken.
- A deployment that was rolled back by ECS still shows as failed in GitHub — that is correct and is the visible signal.
- Never "fix" a failed deployment by deleting task definitions; deregistered revisions cannot be used for rollback.

---

## 10. Phase 9 — Observability: logs and alarms (30 min) — requirement #6

### 10.1 Logs

```powershell
aws logs tail /ecs/ecs-cicd --follow --region ca-west-1
```
**CloudWatch → Logs → Log groups → `/ecs/ecs-cicd`** shows one stream per task. Try **Logs Insights**:

```
fields @timestamp, @message
| filter @message like /GET \/health/
| sort @timestamp desc
| limit 50
```
Container Insights (enabled on the cluster) gives CPU/memory per service under **CloudWatch → Insights → Container Insights**. It adds a small cost.

### 10.2 Alarms and notifications

- `ecs-cicd-unhealthy-hosts` — ALB target group has ≥1 unhealthy target
- `ecs-cicd-target-5xx` — 5 or more 5xx responses from targets in the period
- EventBridge rule — ECS deployment state change (failed/completed) → SNS email

Confirm your SNS subscription (click the link in the email — unconfirmed subscriptions receive nothing; check spam).

### 10.3 Test that the alarm is visible

Safest test, using the CLI to force an alarm state:

```powershell
aws cloudwatch set-alarm-state --alarm-name ecs-cicd-unhealthy-hosts --state-value ALARM --state-reason "manual test" --region ca-west-1
```
You should get the email within a minute and the alarm flips back automatically at the next evaluation. **Only do this when no deployment is running** — the service is configured to roll back on these alarms, so a fake ALARM during a deploy can trigger a real rollback.

A realistic test: set environment variable `FORCE_UNHEALTHY=true` in a new task definition revision (the app then returns 500 on `/health`) and watch the ALB mark targets unhealthy, the alarm fire, the email arrive. Roll back afterwards.

---

## 11. Phase 10 — Measure the AFTER number and write the resume bullet (30 min)

1. Do 3 pipeline deploys (push a trivial change each time, approve promptly).
2. For each, record from the Actions UI: `test`, `build-push`, `deploy` job durations, and the approval wait (excluded).
3. "Commit → live" = push time to the moment the smoke test passes. Use the median of the three.
4. Fill in `docs/metrics.md`; compute the percentage: `(X - Y) / X * 100`.
5. Count manual steps: manual console path (5.3) vs pipeline (1: `git push`, 2: click Approve).

Resume bullet — use your numbers only. Example shape:

> Built a CI/CD pipeline (GitHub Actions → ECR → ECS Fargate) using OIDC federation (no stored AWS keys), cutting deployment time from **X min** to **Y min** and manual steps from **N** to **2**; added automated rollback (circuit breaker + CloudWatch alarms) that restored the last healthy version in **Z min**.

If the pipeline turns out *not* faster than your script, say what improved instead (repeatability, security, rollback, audit trail). Honest framing beats an invented number.

---

## 12. Phase 11 — Clean up (15 min) — don't skip, ALB and public IPv4 cost money by the hour

```powershell
terraform -chdir=infra destroy
```
- ECR has `force_delete = true`, so images do not block the destroy.
- If `create_oidc_provider = true`, destroy also deletes the GitHub OIDC provider — which **breaks any other project in the account that uses it**. If other projects use it, `terraform state rm aws_iam_openid_connect_provider.github` first.
- Afterwards check: EC2 → Load Balancers, ECS → Clusters, CloudWatch → Log groups (log groups are removed by Terraform; check), and Billing → Cost Explorer next day.
- Keep the GitHub repo, screenshots and metrics. The repo variables can stay; they will just point at deleted resources.
- You can re-create the whole thing later from Phase 2.

---

## 13. Phase 12 — Package it for your portfolio (45 min)

### 13.1 Screenshot checklist (redact the 12-digit AWS account ID, role ARNs and your email)

1. Actions run page with 3 green jobs and the approval step
2. "Review deployments" approval dialog
3. Job summary with the deploy time
4. ECS service → Deployments tab (Completed), and the Rolled back example from Demo B
5. ECS service Events tab with rollback timestamps
6. ECR repository with SHA-tagged images and scan results
7. CloudWatch alarms list and the SNS email
8. Zero-downtime loop output
9. Before/after metrics table

### 13.2 Repo hygiene

- Replace placeholders in `README.md` with your real numbers and screenshots (`docs/images/`).
- `git grep -nE "[0-9]{12}"` — remove account IDs. Never commit `terraform.tfvars`, state, or `.env`.
- Add the live-URL note: say the environment was torn down to save cost.

### 13.3 LinkedIn post angles

- "I replaced a 15-step manual deploy with `git push` + one approval click" (with your numbers)
- "Why I use OIDC instead of AWS keys in GitHub Actions"
- "I broke production on purpose — here is how it rolled itself back"

### 13.4 Interview questions you should be able to answer

1. **Why OIDC rather than access keys?** Short-lived credentials, nothing to leak or rotate, trust scoped to repo/branch/environment.
2. **Why two IAM roles?** Least privilege: build can only push to ECR; deploy can only update ECS and pass the task roles. Also the `sub` claim differs for environment jobs.
3. **Why tag images with the git SHA, immutable?** Traceability and safe rollback; `latest` makes it impossible to know what is running.
4. **How does ECS avoid downtime?** 100/200 percent, health checks, deregistration delay.
5. **Circuit breaker vs CloudWatch alarm rollback?** Breaker detects tasks that cannot start/become healthy; alarms detect bad behaviour of tasks that did start.
6. **What does a rollback actually do?** Points the service at an earlier task-definition revision (and image).
7. **Terraform owns the service, the pipeline owns the image. Trade-off?** `ignore_changes` on task_definition avoids Terraform reverting each deploy; but a non-image change made in Terraform to the task definition will not reach the service until it is deployed through the same path. A mature setup would template the task definition in the repo.
8. **Why a multi-stage, non-root image?** Smaller attack surface and size; no build tools in runtime.
9. **Rolling vs blue/green?** Blue/green gives instant cut-over and rollback plus a test listener, at double the capacity cost and more complexity.
10. **What would you add for production?** HTTPS (ACM + Route 53), private subnets + NAT/VPC endpoints, WAF, autoscaling, staging environment, image signing, Terraform in its own pipeline.

---

## Appendix A — Hidden-details checklist

1. Region is `ca-west-1`; check every console page's region selector.
2. `github_org`/`github_repo` match exactly (case-sensitive).
3. Create the `production` environment **before** the first run.
4. Leave "Prevent self-review" off when you are the only reviewer.
5. Private repos on Free plans don't enforce reviewers.
6. One OIDC provider per account.
7. Build role trusts `refs/heads/main`; deploy role trusts `environment:production`.
8. `permissions: id-token: write` is required on any job that assumes a role.
9. Tags are immutable: never re-push the same tag.
10. `--platform linux/amd64` for Fargate X86_64 tasks.
11. ECR login token lasts 12 hours.
12. Slim images have no `curl`; the health check uses Python.
13. Container name in the task definition (`app`) must match the workflow's `CONTAINER_NAME` and the ALB attachment.
14. Health-check grace period must exceed app start time.
15. Target type is `ip` for Fargate (awsvpc).
16. Task security group allows 8080 only from the ALB security group.
17. Execution role (pull image, write logs) ≠ task role (app permissions).
18. Reduce `deregistration_delay` to speed deploys.
19. `wait-for-service-stability` default timeout is 30 minutes; the workflow sets 15.
20. `paths-ignore` means doc-only commits don't deploy.
21. Workflow `concurrency` prevents two deploys racing (no cancel-in-progress).
22. Rollback needs old images: ECR lifecycle keep ≥ 15.
23. Windows: use `curl.exe`, set `$env:AWS_PAGER=""`, write JSON without BOM, `ConvertTo-Json -Depth 20`.
24. `.gitattributes` forces LF for Dockerfile/YAML.
25. Docker Desktop must be running (WSL2 backend).
26. Confirm the SNS subscription email.
27. A fake ALARM during a deploy can trigger a real rollback.
28. Never commit `.tfstate`/`.tfvars`; consider the S3 backend with `use_lockfile = true` (Terraform ≥ 1.10).
29. Destroy when done; ALB and public IPv4 bill hourly.
30. Quote only metrics you measured.

## Appendix B — Quick troubleshooting

| Problem | Look at |
|---|---|
| Tasks keep restarting | ECS → service → Tasks → stopped task "Stopped reason"; CloudWatch log group |
| Targets unhealthy | Target group → Targets tab reason; SG rules; container port/bind address |
| `docker push` denied | Re-run ECR login; check region/account in the URI |
| Workflow can't find variables | Settings → Secrets and variables → Actions → **Variables** tab |
| Terraform says resource exists | Import it or delete the leftover from an earlier attempt |
| `terraform apply` AccessDenied | Your CLI identity lacks permission (`aws sts get-caller-identity`) |
| Deploy red, service fine | Smoke test failed on version mismatch; read the job log |

## Appendix C — What was and was not verified when this project was prepared

Verified: the unit tests pass; workflow YAML and Terraform HCL parse; no secrets in the tree.
**Not run end-to-end:** the Docker image build, `terraform validate/plan/apply`, the PowerShell scripts, and the live GitHub Actions run (no Docker daemon, Terraform binary or AWS account was available). Expect to fix small issues on your first run; the troubleshooting tables above cover the likeliest ones, and every fix you make is good interview material.

