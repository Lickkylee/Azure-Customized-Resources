#!/bin/bash
#===============================================================================
# Script: restore-blob-to-acr.sh
# Description: 从 Azure Blob Storage 批量还原所有镜像到 Azure Container Registry
# Usage: ./restore-blob-to-acr.sh -r <acr-name> -s <storage-account> -c <container-name>
#===============================================================================

set -euo pipefail

#--- 参数定义 ---
ACR_NAME=""
STORAGE_ACCOUNT=""
CONTAINER_NAME="acr-backup"
WORK_DIR="/tmp/acr-restore"
LOG_FILE=""
FAILED_COUNT=0
SUCCESS_COUNT=0
SKIP_COUNT=0
FILTER=""

usage() {
    echo "用法: $0 -r <acr-name> -s <storage-account> [-c <container-name>] [-w <work-dir>] [-f <filter>]"
    echo ""
    echo "参数:"
    echo "  -r, --registry        目标 ACR 名称 (不含 .azurecr.io/.azurecr.cn)"
    echo "  -s, --storage-account 存储账户名称"
    echo "  -c, --container       Blob 容器名称 (默认: acr-backup)"
    echo "  -w, --work-dir        本地临时工作目录 (默认: /tmp/acr-restore)"
    echo "  -f, --filter          按前缀过滤要还原的 blob (例如: myapp)"
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
        -f|--filter)          FILTER="$2";           shift 2 ;;
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
LOG_FILE="${WORK_DIR}/restore-$(date +%Y%m%d-%H%M%S).log"

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg" | tee -a "$LOG_FILE"
}

log "========== ACR 还原开始 =========="
log "ACR:             $ACR_NAME"
log "Storage Account: $STORAGE_ACCOUNT"
log "Container:       $CONTAINER_NAME"
log "Work Dir:        $WORK_DIR"
log "Filter:          ${FILTER:-<无>}"

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

#--- 列出 Blob ---
log "正在列出 Blob..."
BLOB_LIST_ARGS=(
    --account-name "$STORAGE_ACCOUNT"
    --container-name "$CONTAINER_NAME"
    --auth-mode login
    --query "[?ends_with(name, '.tar.gz')].name"
    -o tsv
)
if [[ -n "$FILTER" ]]; then
    BLOB_LIST_ARGS+=(--prefix "$FILTER")
fi

BLOBS=$(az storage blob list "${BLOB_LIST_ARGS[@]}" 2>/dev/null)

if [[ -z "$BLOBS" ]]; then
    log "Blob 容器中没有找到任何 .tar.gz 文件，退出"
    exit 0
fi

BLOB_COUNT=$(echo "$BLOBS" | wc -l)
log "共发现 $BLOB_COUNT 个备份文件"

#--- 从 blob 名称解析原始镜像信息 ---
# Blob 命名规则: repo_tag.tar.gz (备份时 repo 中的 / 被替换为 _)
# 还原时需要用户确认映射关系，因为 _ 可能存在歧义
# 策略: docker load 后读取实际 image name，再 retag 推送到目标 ACR

CURRENT=0
while IFS= read -r blob_name; do
    CURRENT=$((CURRENT + 1))
    log "--- [$CURRENT/$BLOB_COUNT] 处理: $blob_name ---"

    TAR_FILE="${WORK_DIR}/${blob_name}"

    # 下载 blob
    if az storage blob download \
        --account-name "$STORAGE_ACCOUNT" \
        --container-name "$CONTAINER_NAME" \
        --name "$blob_name" \
        --file "$TAR_FILE" \
        --auth-mode login \
        --only-show-errors >> "$LOG_FILE" 2>&1; then
        log "  [Download] 成功, 大小: $(du -h "$TAR_FILE" | cut -f1)"
    else
        log "  [失败] blob download 失败: $blob_name"
        FAILED_COUNT=$((FAILED_COUNT + 1))
        continue
    fi

    # docker load 并获取加载的镜像名称
    LOAD_OUTPUT=$(docker load -i "$TAR_FILE" 2>> "$LOG_FILE")
    if [[ $? -ne 0 ]]; then
        log "  [失败] docker load 失败: $blob_name"
        rm -f "$TAR_FILE"
        FAILED_COUNT=$((FAILED_COUNT + 1))
        continue
    fi
    log "  [Load] $LOAD_OUTPUT"

    # 解析加载的镜像名称 (格式: "Loaded image: registry/repo:tag")
    LOADED_IMAGE=$(echo "$LOAD_OUTPUT" | grep -oP '(?<=Loaded image: ).*' | head -1)
    if [[ -z "$LOADED_IMAGE" ]]; then
        log "  [失败] 无法解析加载的镜像名称"
        rm -f "$TAR_FILE"
        FAILED_COUNT=$((FAILED_COUNT + 1))
        continue
    fi
    log "  [解析] 原始镜像: $LOADED_IMAGE"

    # 提取 repo:tag 部分 (去掉原始 registry 前缀)
    # 例如: old-acr.azurecr.cn/myapp/web:v1 -> myapp/web:v1
    REPO_TAG="${LOADED_IMAGE}"
    # 移除已知的 registry 前缀 (azurecr.io / azurecr.cn / 其他 FQDN)
    if [[ "$REPO_TAG" == *"/"* ]]; then
        # 检查第一段是否包含 . (即为域名)
        FIRST_PART="${REPO_TAG%%/*}"
        if [[ "$FIRST_PART" == *.* ]]; then
            REPO_TAG="${REPO_TAG#*/}"
        fi
    fi

    # 构建目标镜像名称
    TARGET_IMAGE="${LOGIN_SERVER}/${REPO_TAG}"
    log "  [目标] $TARGET_IMAGE"

    # 检查目标 ACR 中是否已存在
    TARGET_REPO="${REPO_TAG%%:*}"
    TARGET_TAG="${REPO_TAG##*:}"
    EXISTING_TAGS=$(az acr repository show-tags --name "$ACR_NAME" --repository "$TARGET_REPO" -o tsv 2>/dev/null || true)
    if echo "$EXISTING_TAGS" | grep -qx "$TARGET_TAG" 2>/dev/null; then
        log "  [跳过] 镜像已存在: $TARGET_IMAGE"
        docker rmi "$LOADED_IMAGE" >> "$LOG_FILE" 2>&1 || true
        rm -f "$TAR_FILE"
        SKIP_COUNT=$((SKIP_COUNT + 1))
        continue
    fi

    # Tag + Push
    if [[ "$LOADED_IMAGE" != "$TARGET_IMAGE" ]]; then
        docker tag "$LOADED_IMAGE" "$TARGET_IMAGE" >> "$LOG_FILE" 2>&1
    fi

    if docker push "$TARGET_IMAGE" >> "$LOG_FILE" 2>&1; then
        log "  [Push] 成功: $TARGET_IMAGE"
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    else
        log "  [失败] docker push 失败: $TARGET_IMAGE"
        FAILED_COUNT=$((FAILED_COUNT + 1))
    fi

    # 清理本地临时文件和镜像
    rm -f "$TAR_FILE"
    docker rmi "$LOADED_IMAGE" >> "$LOG_FILE" 2>&1 || true
    if [[ "$LOADED_IMAGE" != "$TARGET_IMAGE" ]]; then
        docker rmi "$TARGET_IMAGE" >> "$LOG_FILE" 2>&1 || true
    fi

done <<< "$BLOBS"

#--- 汇总 ---
log "========== ACR 还原完成 =========="
log "成功: $SUCCESS_COUNT | 跳过: $SKIP_COUNT | 失败: $FAILED_COUNT"
log "日志文件: $LOG_FILE"

if [[ $FAILED_COUNT -gt 0 ]]; then
    exit 1
fi
