#!/bin/bash
#===============================================================================
# Script: backup-acr-to-blob.sh
# Description: 从 Azure Container Registry 批量备份所有镜像到 Azure Blob Storage
# Usage: ./backup-acr-to-blob.sh -r <acr-name> -s <storage-account> -c <container-name>
#===============================================================================

set -euo pipefail

#--- 参数定义 ---
ACR_NAME=""
STORAGE_ACCOUNT=""
CONTAINER_NAME="acr-backup"
WORK_DIR="/tmp/acr-backup"
LOG_FILE=""
FAILED_COUNT=0
SUCCESS_COUNT=0
SKIP_COUNT=0
OVERWRITE=false

usage() {
    echo "用法: $0 -r <acr-name> -s <storage-account> [-c <container-name>] [-w <work-dir>] [--overwrite]"
    echo ""
    echo "参数:"
    echo "  -r, --registry        ACR 名称 (不含 .azurecr.io/.azurecr.cn)"
    echo "  -s, --storage-account 存储账户名称"
    echo "  -c, --container       Blob 容器名称 (默认: acr-backup)"
    echo "  -w, --work-dir        本地临时工作目录 (默认: /tmp/acr-backup)"
    echo "      --overwrite       覆盖已存在的 blob (默认: 跳过)"
    echo "  -h, --help            显示帮助"
    exit 1
}

#--- 参数解析 ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        -r|--registry)        ACR_NAME="$2";        shift 2 ;;
        -s|--storage-account) STORAGE_ACCOUNT="$2";  shift 2 ;;
        -c|--container)       CONTAINER_NAME="$2";   shift 2 ;;
        -w|--work-dir)        WORK_DIR="$2";         shift 2 ;;
        --overwrite)          OVERWRITE=true;        shift   ;;
        -h|--help)            usage ;;
        *)                    echo "未知参数: $1"; usage ;;
    esac
done

if [[ -z "$ACR_NAME" || -z "$STORAGE_ACCOUNT" ]]; then
    echo "错误: 必须指定 --registry 和 --storage-account"
    usage
fi

#--- 初始化 ---
mkdir -p "$WORK_DIR"
LOG_FILE="${WORK_DIR}/backup-$(date +%Y%m%d-%H%M%S).log"

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg" | tee -a "$LOG_FILE"
}

log "========== ACR 备份开始 =========="
log "ACR:             $ACR_NAME"
log "Storage Account: $STORAGE_ACCOUNT"
log "Container:       $CONTAINER_NAME"
log "Work Dir:        $WORK_DIR"
log "Overwrite:       $OVERWRITE"

#--- 检测 ACR 登录服务器域名 ---
LOGIN_SERVER=$(az acr show --name "$ACR_NAME" --query loginServer -o tsv 2>/dev/null)
if [[ -z "$LOGIN_SERVER" ]]; then
    log "错误: 无法获取 ACR 登录服务器，请检查 ACR 名称和 az 登录状态"
    exit 1
fi
log "Login Server:    $LOGIN_SERVER"

#--- 登录 ACR ---
log "正在登录 ACR..."
az acr login --name "$ACR_NAME" 2>&1 | tee -a "$LOG_FILE"

#--- 确保 Blob 容器存在 ---
log "正在确保 Blob 容器 '$CONTAINER_NAME' 存在..."
az storage container create \
    --account-name "$STORAGE_ACCOUNT" \
    --name "$CONTAINER_NAME" \
    --auth-mode login \
    --only-show-errors > /dev/null 2>&1 || true

#--- 获取所有 Repository ---
log "正在获取 Repository 列表..."
REPOS=$(az acr repository list --name "$ACR_NAME" -o tsv 2>/dev/null)

if [[ -z "$REPOS" ]]; then
    log "ACR 中没有任何 Repository，退出"
    exit 0
fi

REPO_COUNT=$(echo "$REPOS" | wc -l)
log "共发现 $REPO_COUNT 个 Repository"

#--- 遍历每个 Repository 的每个 Tag ---
CURRENT=0
while IFS= read -r repo; do
    log "--- 处理 Repository: $repo ---"

    TAGS=$(az acr repository show-tags --name "$ACR_NAME" --repository "$repo" --orderby time_desc -o tsv 2>/dev/null)

    if [[ -z "$TAGS" ]]; then
        log "  [跳过] $repo 没有任何 tag"
        continue
    fi

    while IFS= read -r tag; do
        CURRENT=$((CURRENT + 1))
        IMAGE="${LOGIN_SERVER}/${repo}:${tag}"
        # Blob 名称: repo 中的 / 替换为 _，格式: repo_tag.tar.gz
        SAFE_NAME=$(echo "${repo}/${tag}" | tr '/' '_')
        BLOB_NAME="${SAFE_NAME}.tar.gz"

        log "  [$CURRENT] 处理: $IMAGE -> $BLOB_NAME"

        # 检查 blob 是否已存在
        if [[ "$OVERWRITE" == "false" ]]; then
            EXISTS=$(az storage blob exists \
                --account-name "$STORAGE_ACCOUNT" \
                --container-name "$CONTAINER_NAME" \
                --name "$BLOB_NAME" \
                --auth-mode login \
                --query exists -o tsv 2>/dev/null)
            if [[ "$EXISTS" == "true" ]]; then
                log "  [跳过] Blob 已存在: $BLOB_NAME"
                SKIP_COUNT=$((SKIP_COUNT + 1))
                continue
            fi
        fi

        TAR_FILE="${WORK_DIR}/${SAFE_NAME}.tar.gz"

        # Pull -> Save -> Upload -> 清理
        if docker pull "$IMAGE" >> "$LOG_FILE" 2>&1; then
            log "  [Pull] 成功"
        else
            log "  [失败] docker pull 失败: $IMAGE"
            FAILED_COUNT=$((FAILED_COUNT + 1))
            continue
        fi

        if docker save "$IMAGE" | gzip > "$TAR_FILE" 2>> "$LOG_FILE"; then
            log "  [Save] 成功, 大小: $(du -h "$TAR_FILE" | cut -f1)"
        else
            log "  [失败] docker save 失败: $IMAGE"
            rm -f "$TAR_FILE"
            FAILED_COUNT=$((FAILED_COUNT + 1))
            continue
        fi

        if az storage blob upload \
            --account-name "$STORAGE_ACCOUNT" \
            --container-name "$CONTAINER_NAME" \
            --name "$BLOB_NAME" \
            --file "$TAR_FILE" \
            --auth-mode login \
            --overwrite "$OVERWRITE" \
            --only-show-errors >> "$LOG_FILE" 2>&1; then
            log "  [Upload] 成功: $BLOB_NAME"
            SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        else
            log "  [失败] blob upload 失败: $BLOB_NAME"
            FAILED_COUNT=$((FAILED_COUNT + 1))
        fi

        # 清理本地临时文件和镜像
        rm -f "$TAR_FILE"
        docker rmi "$IMAGE" >> "$LOG_FILE" 2>&1 || true

    done <<< "$TAGS"
done <<< "$REPOS"

#--- 汇总 ---
log "========== ACR 备份完成 =========="
log "成功: $SUCCESS_COUNT | 跳过: $SKIP_COUNT | 失败: $FAILED_COUNT"
log "日志文件: $LOG_FILE"

if [[ $FAILED_COUNT -gt 0 ]]; then
    exit 1
fi
