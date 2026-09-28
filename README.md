# tf-auto-pipeline

CodePipeline + CodeBuild で **terraform plan → (任意の手動承認) → auto apply** を行うパイプラインを構築する Terraform 一式です。

```
Source (CodeConnections) ─▶ Plan (CodeBuild) ─▶ [Approval (任意)] ─▶ Apply (CodeBuild)
```

- Plan ステージで `terraform plan -detailed-exitcode -out=tfplan` を実行し、差分の有無を `HAS_CHANGES` として後続に渡します。
- Apply ステージは **差分がある場合のみ**、Plan で作成した `tfplan` をそのまま `apply` します（再 plan しないため、plan 後に state が進んでいれば stale エラーで停止します）。
- パイプラインは V2 / `QUEUED` モードで、apply の同時実行を防ぎます。
- plan / apply は別 IAM ロールで実行します（既定: plan = `ReadOnlyAccess`、apply = `AdministratorAccess`）。
- 任意で、結果を GitHub Issue にコメント通知できます。

## ファイル構成

| パス | 内容 |
|---|---|
| `main.tf` | パイプライン本体（S3 アーティファクトバケット、CodeBuild、CodePipeline、IAM） |
| `buildspec/plan.yml` | Plan ステージの buildspec |
| `buildspec/apply.yml` | Apply ステージの buildspec |
| `pipeline.sh` | デプロイ・実行・状態確認用のヘルパースクリプト |
| `terraform.tfvars.example` | 変数ファイルのサンプル |

## 前提

- Terraform >= 1.5、AWS provider >= 5.40
- AWS CLI v2（認証済み）
- ステータスが **Available** の CodeConnections（GitHub 等）接続
- 対象 Terraform が使う S3 backend バケット（`tf_state_bucket`）
  - state ロックは S3 ネイティブロック（`use_lockfile = true`）を想定しています。DynamoDB ロックを使う場合は CodeBuild ロールに DynamoDB の権限を追加してください。

## 使い方

```bash
cp terraform.tfvars.example terraform.tfvars
vi terraform.tfvars            # connection_arn / repository_id / tf_state_bucket などを設定

./pipeline.sh plan             # パイプライン自体の plan のみ
./pipeline.sh deploy           # パイプライン自体を plan -> apply（確認あり。-y でスキップ）
./pipeline.sh run -w           # パイプラインを手動実行し、完了まで待つ
./pipeline.sh status           # 各ステージの状態を表示
./pipeline.sh destroy          # パイプライン一式を削除（対象環境のリソースは削除されません）
```

デプロイ後は `branch` への push で自動的にパイプラインが起動します。

## 主な変数

| 変数 | 必須 | 既定値 | 説明 |
|---|---|---|---|
| `connection_arn` | ✔ | | CodeConnections 接続 ARN |
| `repository_id` | ✔ | | ソースリポジトリ (`owner/repo`) |
| `tf_state_bucket` | ✔ | | 対象 Terraform の S3 backend バケット名 |
| `region` | | `ap-northeast-1` | デプロイ先リージョン |
| `name` | | `tf-auto-pipeline` | リソース名のプレフィックス |
| `branch` | | `main` | 監視するブランチ |
| `tf_working_dir` | | `.` | リポジトリ内で terraform を実行するディレクトリ |
| `terraform_version` | | `1.9.8` | CodeBuild で使う Terraform のバージョン |
| `plan_policy_arns` | | `ReadOnlyAccess` | plan ロールに付与するマネージドポリシー |
| `apply_policy_arns` | | `AdministratorAccess` | apply ロールに付与するマネージドポリシー |
| `enable_manual_approval` | | `false` | Plan と Apply の間に手動承認を挟む |
| `github_token_secret_arn` | | `null` | GitHub トークンを格納した Secrets Manager ARN |
| `github_issue_repo` | | `repository_id` | 通知先リポジトリ |
| `github_issue_number` | | `null` | 通知先 Issue 番号 |

GitHub 通知は `github_token_secret_arn` と `github_issue_number` の両方を指定した場合のみ有効になります。plan 失敗時は Plan ステージから、それ以外（apply 成功/失敗/スキップ）は Apply ステージからコメントします。

## 注意

- `apply_policy_arns` の既定値は検証用途の `AdministratorAccess` です。本番では対象リソースに合わせて絞ってください。
- `terraform.tfvars`・state・plan ファイルは `.gitignore` でコミット対象外にしています。
- `.terraform.lock.hcl` はコミットしていません。プロバイダのバージョンを固定したい場合は、各自の環境で `terraform init` した後、
  `terraform providers lock -platform=linux_amd64 -platform=darwin_arm64` などで必要なプラットフォームのハッシュを揃えてからコミットしてください。
