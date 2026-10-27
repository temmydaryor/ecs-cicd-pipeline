# Measured results

Every number on this page comes from a real run: GitHub Actions run history (read with the `gh` CLI), the request loop output, or the ECS/AWS console. Anything I did **not** measure is listed under "Not measured" instead of being estimated.

## How the numbers were taken

| Item | Method |
|---|---|
| Pipeline stage times | `gh run view <id> --json jobs` for `test` and `build-push`; for `deploy`, `gh api repos/<repo>/actions/runs/<id>/jobs` using the first step start to the last step end |
| Approval wait | **Not** included. GitHub starts the deploy job's clock after approval (job duration and step-based duration differed by only 2-4 s in every run). |
| "Pipeline total" | `test` + `build-push` + active `deploy` time for one run, push to verified-live (the deploy job ends with a smoke test that must see the new commit SHA) |
| Zero-downtime check | PowerShell loop: 1,200 requests, 0.5 s apart, to the ALB `/health` endpoint while a deployment ran; the version in each response was counted |
| Rolled-back release | Deliberately changed the container bind port in the Dockerfile (unit tests and image build still pass, container is unreachable by the load balancer) |

## 1. Pipeline duration (7 successful runs, build step really executed in each)

| Run ID | test (s) | build-push (s) | deploy (s) | Total (s) | Total (min) | deploy share |
|---|---|---|---|---|---|---|
| 38856914798 | 30 | 32 | 204 | 266 | 4.4 | 77% |
| 38857575455 | 17 | 29 | 271 | 317 | 5.3 | 85% |
| 39543905998 | 19 | 33 | 436 | 488 | 8.1 | 89% |
| 39539347227 | 20 | 38 | 536 | 594 | 9.9 | 90% |
| 39541588126 | 30 | 33 | 536 | 599 | 10.0 | 90% |
| 39549974049 | 23 | 42 | 754 | 819 | 13.7 | 92% |
| 39530335616 | 27 | 35 | 838 | 900 | 15.0 | 93% |
| **Median** | **23** | **33** | **536** | **594** | **9.9** | |

- Median pipeline time: **594 s (about 10 minutes)**; range 266-900 s (4.4-15.0 min).
- `test` + `build-push` is roughly one minute. The ECS rolling update is **77-93%** of the total.
- One console-observed ECS rollout (start 23:32, complete 23:37) took 4 min 53 s.
- The spread in deploy time is real variation in how long ECS took to finish rollouts (health checks, connection draining); I did not isolate the cause.

## 2. Zero-downtime rolling deployment

- Loop: 1,200 requests, 0.5 s apart, against the ALB during a deployment.
- Responses by version: `c3cb2a6` = 219, `ffc8af1` = 981. **Total = 1,200**, equal to the number of requests the loop sends, so every request received an answer (0 failed). Both versions were served during the test, which shows the cut-over happened under live traffic.
- The loop's own `ok=` / `fail=` line was not saved; the 0-failure conclusion comes from the per-version counts adding up to the full request count.
- Mechanism: `minimum_healthy_percent = 100`, `maximum_percent = 200`, ALB health checks, 30 s deregistration delay.

## 3. Safety nets (each demonstrated)

| Layer | Evidence |
|---|---|
| CI gate | Run 39541316030 ("Demo: broken test"): `test` failed after 13 s; `build-push` and `deploy` never started |
| ECS circuit breaker rollback | Runs 39541931612 and 39548200017 (container bound to the wrong port): `test` and `build-push` passed, the rollout failed, ECS reported *"Service deployment rolled back because the circuit breaker threshold was exceeded"*, the previous version kept serving. The pipeline's deploy job ended as failed after **329 s** and **591 s** respectively (approval to failure reported). |
| Recovery | Reverting the bad commit produced green runs (39543905998, 39549974049) and a healthy version |
| Alerting | An SNS email notification was received during the bad-release test |
| Auth | GitHub OIDC to two least-privilege roles (build = ECR push only, deploy = ECS update only); no AWS keys stored in GitHub |

Rollback detection time (approval until the failure was reported): **5.5 min and 9.9 min** on the two runs. Two samples is too few to quote a median.

## 4. Measured from my own screenshots (terminal and console)

| Item | Result |
|---|---|
| Image size, single-stage vs multi-stage | `docker image ls`: single-stage build **1.63 GB** vs multi-stage slim build **187 MB** (about 89% smaller) |
| Manual deploy, machine time only | `manual-deploy.ps1` printed **315.5 s (about 5.3 min)** for `manual-v2` and **346.9 s (about 5.8 min)** for `manual-v3`; of that, "update service + wait for stable" was 303.2 s and 334.3 s. Two runs only, so no median is quoted |
| ECS rollout in the console | One rolling deployment: started 23:32, completed 23:37 (**4 min 53 s**) |
| Circuit-breaker rollback in the console | Bad release started 23:14, ECS reported "rolled back" by 23:17 (about **3 min**) |

How to read the manual number: it counts only the time the script ran. It leaves out the hands-on work (typing the commands, the console steps in section 5.3 of `GUIDE.md`). The pipeline's 594 s median includes tests, the ECR scan check and the smoke test, and it needs only a push and one approval click. I do not claim the pipeline is faster in wall-clock time; the gain is fewer manual actions and built-in safety checks.

## Not measured (do not quote these)

| Item | Why |
|---|---|
| "% faster" than manual | Manual hands-on time was not stopwatch-timed, and machine time is not a like-for-like comparison |
| Manual rollback (`rollback.yml` / `rollback.ps1`) | Not confirmed as run, so it is not claimed |

## Manual effort

- Pipeline: **2 actions per release** (`git push`, then one Approve click).
- Manual path (section 5.3 of `GUIDE.md`): several commands plus the console steps; count them yourself if you want to quote a number.

## Resume bullets (only use what is true for you)

- Built a CI/CD pipeline (GitHub Actions to Amazon ECR to ECS Fargate) with OIDC federation (no stored AWS keys), an approval gate and automatic rollback; releases go from push to verified-live in a median of about 10 minutes with one approval click.
- Cut the container image from 1.63 GB to 187 MB with a multi-stage build and pinned it to immutable ECR tags with scan-on-push.
- Validated zero-downtime rolling deployments: 1,200 requests served across a live rollout with no failures, across two versions.
- Proved the safety nets: a failing test was stopped by the CI gate in 13 seconds, and a bad release (wrong container port) was automatically rolled back by the ECS deployment circuit breaker while the previous version kept serving traffic.
- Wrote Terraform for the full stack (ECR with scan on push and immutable tags, ALB, ECS service with circuit breaker, CloudWatch alarms and SNS alerts, least-privilege IAM roles).
