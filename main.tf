############################################################
# Terraform Auto Pipeline
#   Source (CodeConnections) -> Plan (CodeBuild)
#   -> [Approval (任意)] -> Apply (CodeBuild)
#   plan が成功 & 差分ありの場合のみ apply -auto-approve
############################################################

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.40"
    }
  }
}

provider "aws" {
  region = var.region
}

# ----------------------------------------------------------
# Variables
# ----------------------------------------------------------
variable "region" {
  type    = string
  default = "ap-northeast-1"
}

variable "name" {
  description = "リソース名のプレフィックス（小文字・ハイフン推奨）"
  type        = string
  default     = "tf-auto-pipeline"
}

variable "connection_arn" {
  description = "ステータスが Available の CodeConnections 接続 ARN"
  type        = string
}

variable "repository_id" {
  description = "ソースリポジトリ (owner/repo)"
  type        = string
}

variable "branch" {
  type    = string
  default = "main"
}

variable "tf_working_dir" {
  description = "リポジトリ内で terraform を実行するディレクトリ"
  type        = string
  default     = "."
}

variable "terraform_version" {
  description = "CodeBuild 上で使う Terraform のバージョン"
  type        = string
  default     = "1.9.8"
}

variable "tf_state_bucket" {
  description = "対象 Terraform の S3 backend バケット名（state/lockfile 用の権限付与に使用）"
  type        = string
}

variable "plan_policy_arns" {
  description = "plan 用 CodeBuild ロールに付与するマネージドポリシー"
  type        = list(string)
  default     = ["arn:aws:iam::aws:policy/ReadOnlyAccess"]
}

variable "apply_policy_arns" {
  description = "apply 用 CodeBuild ロールに付与するマネージドポリシー（検証用途なので強め）"
  type        = list(string)
  default     = ["arn:aws:iam::aws:policy/AdministratorAccess"]
}

variable "enable_manual_approval" {
  description = "true にすると Plan と Apply の間に手動承認を挟む"
  type        = bool
  default     = false
}

# --- GitHub Issue 通知（3つとも指定しない場合は無効） ---
variable "github_token_secret_arn" {
  description = "GitHub トークン（プレーンテキスト）を格納した Secrets Manager の ARN"
  type        = string
  default     = null
}

variable "github_issue_repo" {
  description = "コメント先リポジトリ (owner/repo)。未指定なら repository_id"
  type        = string
  default     = null
}

variable "github_issue_number" {
  description = "結果をコメントする Issue 番号"
  type        = number
  default     = null
}

# ----------------------------------------------------------
# Locals
# ----------------------------------------------------------
locals {
  notify = var.github_token_secret_arn != null && var.github_issue_number != null

  build_env = merge(
    {
      TF_VERSION     = var.terraform_version
      TF_WORKING_DIR = var.tf_working_dir
    },
    {
      for k, v in {
        GITHUB_REPO         = coalesce(var.github_issue_repo, var.repository_id)
        GITHUB_ISSUE_NUMBER = tostring(var.github_issue_number)
      } : k => v if local.notify
    }
  )

  stages = {
    plan  = { buildspec = "plan.yml", policy_arns = var.plan_policy_arns }
    apply = { buildspec = "apply.yml", policy_arns = var.apply_policy_arns }
  }

  policy_attachments = merge([
    for stage, cfg in local.stages : {
      for arn in cfg.policy_arns : "${stage}|${arn}" => { stage = stage, arn = arn }
    }
  ]...)
}

# ----------------------------------------------------------
# Artifact bucket / Logs
# ----------------------------------------------------------
resource "aws_s3_bucket" "artifacts" {
  bucket_prefix = "${var.name}-artifacts-"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket                  = aws_s3_bucket.artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_cloudwatch_log_group" "build" {
  name              = "/codebuild/${var.name}"
  retention_in_days = 14
}

# ----------------------------------------------------------
# CodeBuild IAM (plan / apply で別ロール)
# ----------------------------------------------------------
data "aws_iam_policy_document" "codebuild_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["codebuild.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "codebuild" {
  for_each           = local.stages
  name               = "${var.name}-${each.key}-codebuild"
  assume_role_policy = data.aws_iam_policy_document.codebuild_assume.json
}

data "aws_iam_policy_document" "codebuild_base" {
  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.build.arn}:*"]
  }

  statement {
    sid       = "PipelineArtifacts"
    actions   = ["s3:GetObject", "s3:GetObjectVersion", "s3:PutObject"]
    resources = ["${aws_s3_bucket.artifacts.arn}/*"]
  }

  statement {
    sid       = "TfStateList"
    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::${var.tf_state_bucket}"]
  }

  statement {
    sid       = "TfStateObjects"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["arn:aws:s3:::${var.tf_state_bucket}/*"]
  }

  dynamic "statement" {
    for_each = local.notify ? [var.github_token_secret_arn] : []
    content {
      sid       = "GitHubToken"
      actions   = ["secretsmanager:GetSecretValue"]
      resources = [statement.value]
    }
  }
}

resource "aws_iam_role_policy" "codebuild_base" {
  for_each = local.stages
  name     = "base"
  role     = aws_iam_role.codebuild[each.key].id
  policy   = data.aws_iam_policy_document.codebuild_base.json
}

resource "aws_iam_role_policy_attachment" "codebuild" {
  for_each   = local.policy_attachments
  role       = aws_iam_role.codebuild[each.value.stage].name
  policy_arn = each.value.arn
}

# ----------------------------------------------------------
# CodeBuild projects
# ----------------------------------------------------------
resource "aws_codebuild_project" "this" {
  for_each      = local.stages
  name          = "${var.name}-${each.key}"
  service_role  = aws_iam_role.codebuild[each.key].arn
  build_timeout = 60

  artifacts {
    type = "CODEPIPELINE"
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = file("${path.module}/buildspec/${each.value.buildspec}")
  }

  environment {
    type         = "LINUX_CONTAINER"
    compute_type = "BUILD_GENERAL1_SMALL"
    image        = "aws/codebuild/amazonlinux-x86_64-standard:5.0"

    dynamic "environment_variable" {
      for_each = local.build_env
      content {
        name  = environment_variable.key
        value = environment_variable.value
      }
    }

    dynamic "environment_variable" {
      for_each = local.notify ? [var.github_token_secret_arn] : []
      content {
        name  = "GITHUB_TOKEN"
        type  = "SECRETS_MANAGER"
        value = environment_variable.value
      }
    }
  }

  logs_config {
    cloudwatch_logs {
      group_name  = aws_cloudwatch_log_group.build.name
      stream_name = each.key
    }
  }

  depends_on = [aws_iam_role_policy.codebuild_base]
}

# ----------------------------------------------------------
# CodePipeline IAM
# ----------------------------------------------------------
data "aws_iam_policy_document" "pipeline_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["codepipeline.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "pipeline" {
  name               = "${var.name}-codepipeline"
  assume_role_policy = data.aws_iam_policy_document.pipeline_assume.json
}

data "aws_iam_policy_document" "pipeline" {
  statement {
    sid = "Artifacts"
    actions = [
      "s3:GetObject", "s3:GetObjectVersion", "s3:PutObject",
      "s3:GetBucketVersioning", "s3:GetBucketLocation",
    ]
    resources = [aws_s3_bucket.artifacts.arn, "${aws_s3_bucket.artifacts.arn}/*"]
  }

  statement {
    sid       = "CodeBuild"
    actions   = ["codebuild:StartBuild", "codebuild:BatchGetBuilds"]
    resources = [for p in aws_codebuild_project.this : p.arn]
  }

  statement {
    sid       = "Connection"
    actions   = ["codeconnections:UseConnection", "codestar-connections:UseConnection"]
    resources = [var.connection_arn]
  }
}

resource "aws_iam_role_policy" "pipeline" {
  name   = "pipeline"
  role   = aws_iam_role.pipeline.id
  policy = data.aws_iam_policy_document.pipeline.json
}

# ----------------------------------------------------------
# CodePipeline (V2 / QUEUED: apply の同時実行を防ぐ)
# ----------------------------------------------------------
resource "aws_codepipeline" "this" {
  name           = var.name
  role_arn       = aws_iam_role.pipeline.arn
  pipeline_type  = "V2"
  execution_mode = "QUEUED"

  artifact_store {
    location = aws_s3_bucket.artifacts.bucket
    type     = "S3"
  }

  stage {
    name = "Source"
    action {
      name             = "Source"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeStarSourceConnection"
      version          = "1"
      output_artifacts = ["SourceOutput"]
      configuration = {
        ConnectionArn        = var.connection_arn
        FullRepositoryId     = var.repository_id
        BranchName           = var.branch
        OutputArtifactFormat = "CODE_ZIP"
        DetectChanges        = "true"
      }
    }
  }

  stage {
    name = "Plan"
    action {
      name             = "TerraformPlan"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
      namespace        = "PlanVars"
      input_artifacts  = ["SourceOutput"]
      output_artifacts = ["PlanOutput"]
      configuration = {
        ProjectName = aws_codebuild_project.this["plan"].name
        EnvironmentVariables = jsonencode([
          { name = "PIPELINE_EXECUTION_ID", value = "#{codepipeline.PipelineExecutionId}", type = "PLAINTEXT" },
        ])
      }
    }
  }

  dynamic "stage" {
    for_each = var.enable_manual_approval ? [1] : []
    content {
      name = "Approval"
      action {
        name     = "Approve"
        category = "Approval"
        owner    = "AWS"
        provider = "Manual"
        version  = "1"
        configuration = {
          CustomData = "Plan ステージのログを確認してから承認してください"
        }
      }
    }
  }

  stage {
    name = "Apply"
    action {
      name            = "TerraformApply"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      version         = "1"
      input_artifacts = ["SourceOutput", "PlanOutput"]
      configuration = {
        ProjectName   = aws_codebuild_project.this["apply"].name
        PrimarySource = "SourceOutput"
        EnvironmentVariables = jsonencode([
          { name = "HAS_CHANGES", value = "#{PlanVars.HAS_CHANGES}", type = "PLAINTEXT" },
          { name = "PIPELINE_EXECUTION_ID", value = "#{codepipeline.PipelineExecutionId}", type = "PLAINTEXT" },
        ])
      }
    }
  }
}

# ----------------------------------------------------------
# Outputs
# ----------------------------------------------------------
output "pipeline_name" {
  value = aws_codepipeline.this.name
}

output "pipeline_console_url" {
  value = "https://${var.region}.console.aws.amazon.com/codesuite/codepipeline/pipelines/${aws_codepipeline.this.name}/view?region=${var.region}"
}
