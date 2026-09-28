#!/usr/bin/env bash
#
# tf-auto-pipeline 操作スクリプト（AWS 認証済み前提）
#
# 使い方:
#   ./pipeline.sh deploy   [-y]   # パイプライン自体を plan -> apply
#   ./pipeline.sh plan            # パイプライン自体の plan のみ
#   ./pipeline.sh run      [-w]   # パイプラインを手動実行（-w で完了まで待つ）
#   ./pipeline.sh status          # 各ステージの状態を表示
#   ./pipeline.sh destroy  [-y]   # パイプライン一式を削除
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

TFVARS="terraform.tfvars"
PLAN_FILE=".pipeline.tfplan"
AUTO_YES=false
WAIT=false
PLAN_HAS_CHANGES=false

# ---------- helpers ----------
info()  { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
error() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  sed -n '3,11p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
}

confirm() {
  ${AUTO_YES} && return 0
  local ans
  read -r -p "$1 [y/N]: " ans
  [[ "${ans}" =~ ^[Yy]$ ]] || { info "中止しました"; exit 0; }
}

require_cmds() {
  local c
  for c in terraform aws; do
    command -v "${c}" >/dev/null 2>&1 || error "${c} が見つかりません"
  done
}

require_tfvars() {
  [[ -f "${TFVARS}" ]] || error "${TFVARS} がありません（terraform.tfvars.example をコピーして編集してください）"
  local f
  for f in buildspec/plan.yml buildspec/apply.yml; do
    [[ -f "${f}" ]] || error "${f} がありません"
  done
}

show_identity() {
  local account arn region
  account=$(aws sts get-caller-identity --query Account --output text) \
    || error "AWS 認証情報を取得できません"
  arn=$(aws sts get-caller-identity --query Arn --output text)
  region=$(tf_var region)
  info "Account : ${account}"
  info "Caller  : ${arn}"
  info "Region  : ${region}"
}

tf_init() {
  info "terraform init"
  terraform init -input=false -upgrade=false >/dev/null
}

# terraform.tfvars / デフォルト値込みで変数を評価する
tf_var() {
  echo "var.$1" | terraform console 2>/dev/null | tr -d '"'
}

tf_out() {
  terraform output -raw "$1" 2>/dev/null || true
}

check_connection() {
  local conn status
  conn=$(tf_var connection_arn)
  [[ -n "${conn}" ]] || error "connection_arn が取得できません"

  status=$(aws codeconnections get-connection --connection-arn "${conn}" \
             --query 'Connection.ConnectionStatus' --output text 2>/dev/null \
        || aws codestar-connections get-connection --connection-arn "${conn}" \
             --query 'Connection.ConnectionStatus' --output text 2>/dev/null \
        || echo "UNKNOWN")

  case "${status}" in
    AVAILABLE) info "Connection: AVAILABLE" ;;
    PENDING)   error "Connection が PENDING です。コンソールで接続を承認してください: ${conn}" ;;
    *)         warn  "Connection の状態を確認できませんでした (${status})。続行します" ;;
  esac
}

check_github_secret() {
  local secret
  secret=$(tf_var github_token_secret_arn)
  [[ -z "${secret}" || "${secret}" == "null" ]] && { info "GitHub 通知: 無効"; return 0; }

  if aws secretsmanager describe-secret --secret-id "${secret}" >/dev/null 2>&1; then
    info "GitHub 通知: 有効 (secret 確認OK)"
  else
    error "Secrets Manager のシークレットが見つかりません: ${secret}"
  fi
}

pipeline_name() {
  local name
  name=$(tf_out pipeline_name)
  [[ -n "${name}" ]] || error "パイプラインがまだデプロイされていません（./pipeline.sh deploy を先に実行）"
  echo "${name}"
}

# ---------- commands ----------
cmd_plan() {
  require_tfvars
  tf_init
  show_identity
  check_connection
  check_github_secret

  info "terraform plan"
  set +e
  terraform plan -input=false -detailed-exitcode -out="${PLAN_FILE}"
  local rc=$?
  set -e
  case ${rc} in
    0) info "差分なし"; PLAN_HAS_CHANGES=false ;;
    2) info "差分あり"; PLAN_HAS_CHANGES=true ;;
    *) error "terraform plan が失敗しました" ;;
  esac
}

cmd_deploy() {
  cmd_plan
  if ! ${PLAN_HAS_CHANGES}; then
    rm -f "${PLAN_FILE}"
    info "適用するものはありません"
    return 0
  fi

  confirm "上記の plan を apply しますか？"
  terraform apply -input=false "${PLAN_FILE}"
  rm -f "${PLAN_FILE}"

  echo
  info "デプロイ完了"
  info "Pipeline: $(tf_out pipeline_name)"
  info "Console : $(tf_out pipeline_console_url)"
}

cmd_run() {
  tf_init
  local name exec_id
  name=$(pipeline_name)
  exec_id=$(aws codepipeline start-pipeline-execution --name "${name}" \
              --query pipelineExecutionId --output text)
  info "実行開始: ${name} (execution: ${exec_id})"
  info "Console : $(tf_out pipeline_console_url)"

  ${WAIT} || return 0

  local st
  while :; do
    st=$(aws codepipeline get-pipeline-execution --pipeline-name "${name}" \
           --pipeline-execution-id "${exec_id}" \
           --query 'pipelineExecution.status' --output text)
    printf '\r\033[K[%s] status: %s' "$(date +%H:%M:%S)" "${st}"
    case "${st}" in
      Succeeded) echo; info "成功しました"; return 0 ;;
      Failed|Stopped|Superseded|Cancelled)
        echo; cmd_status; error "終了ステータス: ${st}" ;;
      *) ;;
    esac
    sleep 15
  done
}

cmd_status() {
  tf_init
  local name
  name=$(pipeline_name)
  info "Pipeline: ${name}"
  aws codepipeline get-pipeline-state --name "${name}" \
    --query 'stageStates[].{Stage:stageName,Status:latestExecution.status,Action:actionStates[0].latestExecution.status,Summary:actionStates[0].latestExecution.summary,Updated:actionStates[0].latestExecution.lastStatusChange}' \
    --output table
}

cmd_destroy() {
  require_tfvars
  tf_init
  show_identity
  warn "パイプライン一式（アーティファクトバケット含む）を削除します。対象環境のリソースは削除されません。"
  confirm "本当に destroy しますか？"
  terraform destroy -input=false -auto-approve
}

# ---------- main ----------
[[ $# -ge 1 ]] || usage
CMD="$1"; shift

while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes)  AUTO_YES=true ;;
    -w|--wait) WAIT=true ;;
    -h|--help) usage ;;
    *) error "不明なオプション: $1" ;;
  esac
  shift
done

require_cmds

case "${CMD}" in
  deploy)  cmd_deploy ;;
  plan)    cmd_plan ;;
  run)     cmd_run ;;
  status)  cmd_status ;;
  destroy) cmd_destroy ;;
  *)       usage ;;
esac
