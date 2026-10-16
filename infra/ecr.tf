resource "aws_ecr_repository" "app" {
  name = "${var.project_name}-app"

  # IMMUTABLE: a tag (the git SHA) can never be overwritten, so "what is running"
  # is always traceable to one commit. It also means you can NOT push :latest twice.
  image_tag_mutability = "IMMUTABLE"

  # Lets `terraform destroy` delete the repo even though it contains images.
  force_delete = true

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep only the 15 most recent images (storage is billed per GB)"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 15
        }
        action = { type = "expire" }
      }
    ]
  })
}
