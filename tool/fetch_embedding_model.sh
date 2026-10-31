#!/usr/bin/env bash
#
# 下载手机端语义检索用的 ONNX 模型与词表。
#
# 用法：
#   ./tool/fetch_embedding_model.sh                # 默认 int8 量化版（约 24MB，推荐）
#   ./tool/fetch_embedding_model.sh fp32           # 全精度版（约 95MB，精度略高）
#   HF_ENDPOINT=https://hf-mirror.com ./tool/fetch_embedding_model.sh   # 国内走镜像
#
# 为什么用 int8 量化版：
#   bge-small-zh-v1.5 只有 24M 参数，量化后 24MB，手机内存占用与推理耗时
#   都降一个量级，而检索排序效果几乎无损（向量检索比的是相对顺序，不是绝对数值）。
#
set -euo pipefail

VARIANT="${1:-quantized}"
case "$VARIANT" in
  quantized|fp32|fp16|int8|uint8|q4|q4f16)
    ;;
  *)
    echo "不支持的变体：$VARIANT"
    echo "可选：quantized | fp32 | fp16 | int8 | uint8 | q4 | q4f16"
    exit 1
    ;;
esac

HF_ENDPOINT="${HF_ENDPOINT:-https://huggingface.co}"
HF_ENDPOINT="${HF_ENDPOINT%/}"
REPO="Xenova/bge-small-zh-v1.5"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
OUT_DIR="$PROJECT_ROOT/assets/models"

mkdir -p "$OUT_DIR"

echo "→ 源站：$HF_ENDPOINT"
echo "→ 仓库：$REPO"
echo "→ 变体：$VARIANT"
echo "→ 目标：$OUT_DIR"

download() {
  local url="$1"
  local target="$2"
  local tmp="${target}.part"
  echo "   下载 $(basename "$target") ..."
  if ! curl -fL --retry 3 --retry-delay 2 --connect-timeout 20 \
      -o "$tmp" "$url"; then
    rm -f "$tmp"
    echo "   失败：$url"
    return 1
  fi
  mv "$tmp" "$target"
}

download \
  "$HF_ENDPOINT/$REPO/resolve/main/onnx/model_${VARIANT}.onnx" \
  "$OUT_DIR/bge-small-zh-v1.5.onnx"

download \
  "$HF_ENDPOINT/$REPO/resolve/main/vocab.txt" \
  "$OUT_DIR/vocab.txt"

MODEL_BYTES=$(wc -c < "$OUT_DIR/bge-small-zh-v1.5.onnx" | tr -d ' ')
VOCAB_LINES=$(wc -l < "$OUT_DIR/vocab.txt" | tr -d ' ')

if [ "$MODEL_BYTES" -lt 1000000 ]; then
  echo "✗ 模型文件只有 ${MODEL_BYTES} 字节，下载可能不完整"
  exit 1
fi

echo
echo "✓ 完成"
echo "  模型：$(basename "$OUT_DIR/bge-small-zh-v1.5.onnx")  ${MODEL_BYTES} 字节"
echo "  词表：vocab.txt  ${VOCAB_LINES} 行"
echo
echo "接下来重新构建 App 即可（flutter build apk / ios / macos）。"
echo "没有模型时 App 不会崩溃，只是降级成纯关键词检索。"
