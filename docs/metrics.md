# Before / After metrics (fill this in with YOUR real numbers)

Do not publish a number you did not measure. Run each scenario 3 times and record the **median**.

## Definitions (keep them identical for both columns)

| Term | Meaning |
|---|---|
| Start | The moment you finish editing code and begin deploying (manual) / the moment you `git push` (pipeline) |
| End | The moment `GET /health` on the public ALB URL returns the NEW version |
| Approval wait | Time the pipeline sits waiting for you to click Approve. **Exclude it** and say so. |

## Manual deploy (`scripts/manual-deploy.ps1`, plus your own clicking/typing time)

| Run | docker build (s) | push (s) | register task def (s) | update + stable (s) | Machine total (s) | Your hands-on extra (s) | End-to-end (s) |
|---|---|---|---|---|---|---|---|
| 1 | | | | | | | |
| 2 | | | | | | | |
| 3 | | | | | | | |
| **Median** | | | | | | | **X** |

## Pipeline deploy (GitHub Actions)

| Run | test job (s) | build-push job (s) | approval wait (s, excluded) | deploy job (s) | Pipeline total excl. approval (s) | Commit -> live (s) |
|---|---|---|---|---|---|---|
| 1 | | | | | | |
| 2 | | | | | | |
| 3 | | | | | | |
| **Median** | | | | | | **Y** |

## Other numbers worth recording

| Metric | How to get it | Value |
|---|---|---|
| Image size, single-stage baseline | `docker image ls` | |
| Image size, multi-stage slim | `docker image ls` | |
| Auto-rollback detection -> restored (s) | ECS service Events tab timestamps | |
| Manual steps per deploy, before -> after | count them | |
| Failed requests during a deploy | zero-downtime loop in the guide | |

“1,200 requests across a rolling deployment (versions c3cb2a6 → ffc8af1): N failed.” Use the real fail number.

## Resume bullet templates (replace X, Y, Z with measured values)

- Built a CI/CD pipeline (GitHub Actions -> ECR -> ECS Fargate) with OIDC federation, cutting deployment time from **X min** (manual) to **Y min** (automated) and removing **N** manual steps per release.
- Implemented automated rollback (ECS deployment circuit breaker + CloudWatch alarms) that restored the last healthy version in **Z min** with zero failed requests during rolling deploys.
- Reduced container image size from **A MB to B MB** (**P%**) using multi-stage builds and a non-root runtime, with ECR vulnerability scanning on every push.
