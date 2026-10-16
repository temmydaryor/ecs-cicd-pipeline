# ---------------------------------------------------------------------------
# GitHub Actions -> AWS via OIDC (no access keys stored in GitHub, ever).
# Two roles = least privilege:
#   build  role: can ONLY push/scan images in this one ECR repo   (main branch)
#   deploy role: can ONLY update this ECS service                  (production environment)
# ---------------------------------------------------------------------------
resource "aws_iam_openid_connect_provider" "github" {
  count          = var.create_oidc_provider ? 1 : 0
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  # AWS validates GitHub's certificate chain itself; a thumbprint is still a required
  # argument for this resource, so a placeholder is accepted.
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

data "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 0 : 1
  url   = "https://token.actions.githubusercontent.com"
}

locals {
  oidc_provider_arn = var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.github[0].arn
  repo_slug         = "${var.github_org}/${var.github_repo}"
  # Classic repos send  repo:ORG/REPO:...   Newer repos send  repo:ORG@ID/REPO@ID:...
  sub_prefix = var.github_sub_prefix != "" ? var.github_sub_prefix : "repo:${local.repo_slug}"
}

# HIDDEN DETAIL: the `sub` claim GitHub sends CHANGES when a job uses an environment.
#   no environment : repo:ORG/REPO:ref:refs/heads/main
#   environment    : repo:ORG/REPO:environment:production
# If the trust policy expects the wrong one you get "Not authorized to perform
# sts:AssumeRoleWithWebIdentity". That is why each role trusts a different sub.
data "aws_iam_policy_document" "build_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["${local.sub_prefix}:ref:refs/heads/main"]
    }
  }
}

data "aws_iam_policy_document" "deploy_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["${local.sub_prefix}:environment:${var.github_environment}"]
    }
  }
}

# ----- build role -----
resource "aws_iam_role" "github_build" {
  name               = "${var.project_name}-github-build"
  assume_role_policy = data.aws_iam_policy_document.build_trust.json
}

data "aws_iam_policy_document" "build" {
  statement {
    sid       = "EcrLogin"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"] # this one action does not support resource-level permissions
  }
  statement {
    sid = "EcrPushAndScanRead"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
      "ecr:BatchGetImage",
      "ecr:DescribeImages",
      "ecr:DescribeImageScanFindings",
    ]
    resources = [aws_ecr_repository.app.arn]
  }
}

resource "aws_iam_role_policy" "build" {
  name   = "ecr-push"
  role   = aws_iam_role.github_build.id
  policy = data.aws_iam_policy_document.build.json
}

# ----- deploy role -----
resource "aws_iam_role" "github_deploy" {
  name               = "${var.project_name}-github-deploy"
  assume_role_policy = data.aws_iam_policy_document.deploy_trust.json
}

data "aws_iam_policy_document" "deploy" {
  statement {
    sid = "EcsDeployReadOnlyAndRegister"
    # Describe*/List*/Register* do not support resource-level restriction.
    actions = [
      "ecs:RegisterTaskDefinition",
      "ecs:DescribeTaskDefinition",
      "ecs:ListTaskDefinitions",
      "ecs:DescribeServices",
      "ecs:DescribeTasks",
      "ecs:ListTasks",
    ]
    resources = ["*"]
  }
  statement {
    sid       = "EcsUpdateThisService"
    actions   = ["ecs:UpdateService"]
    resources = [aws_ecs_service.app.id]
  }
  statement {
    sid       = "PassOnlyTheTwoTaskRoles"
    actions   = ["iam:PassRole"]
    resources = [aws_iam_role.task_execution.arn, aws_iam_role.task.arn]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "deploy" {
  name   = "ecs-deploy"
  role   = aws_iam_role.github_deploy.id
  policy = data.aws_iam_policy_document.deploy.json
}
