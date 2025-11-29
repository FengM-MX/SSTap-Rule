#!/bin/bash

# =============================
# 配置参数
# =============================
RULES_DIR="rules"
OUTPUT_DIR="rules-clash"
MERGED_YAML="category-games-foreign.yml"

# 并行任务数（根据 CPU 核心自动设置，也可手动调整）
JOBS=$(nproc --all)

# 创建临时工作空间
TEMP_WORK_DIR=$(pwd)/.tmp
TEMP_IP_LIST="$TEMP_WORK_DIR/ip_list.txt"
# 清理临时文件
mkdir -p $TEMP_WORK_DIR
rm -rf $TEMP_WORK_DIR/*
# 初始化空文件
> "$TEMP_IP_LIST"  


# 检查是否安装了 parallel，否则降级为单线程
if ! command -v parallel; then
    echo "⚠️ 未检测到 'parallel'，将使用单线程处理。建议安装：sudo apt install parallel"
    USE_PARALLEL=false
else
    USE_PARALLEL=true
fi

# 检查 rules 目录
if [[ ! -d "$RULES_DIR" ]]; then
    echo "❌ 错误: 目录 '$RULES_DIR' 不存在！"
    exit 1
fi

# 创建输出目录
echo "⚠️ 开始清理结果目录$OUTPUT_DIR"
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

echo "⚠️ 开始清理结果文件$MERGED_YAML"
rm -rf $MERGED_YAML

echo "🚀 开始处理 '$RULES_DIR/' 中的规则文件..."
files=("$RULES_DIR"/*)
file_list=()
for f in "${files[@]}"; do
    [[ -f "$f" ]] && file_list+=("$f")
done

total_files=${#file_list[@]}
if [[ $total_files -eq 0 ]]; then
    echo "❌ 错误: '$RULES_DIR/' 中没有可处理的文件。"
    exit 1
fi

echo "📦 共发现 $total_files 个文件，准备使用 $JOBS 个并行任务进行处理..."

# 函数：处理单个文件
process_file() {
    local index="$1"
    local total="$2"
    local filepath="$3"

    local filename=$(basename "$filepath")
    local name_no_ext="${filename%.*}"
    local output_yaml="$OUTPUT_DIR/${name_no_ext}.yaml"

    # 写入 payload:
    echo "payload:" > "$output_yaml"

    # 逐行读取，跳过注释，提取合法 CIDR
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue  # 跳过注释

        # 提取所有疑似 CIDR
        echo "$line" | grep -oE '\b([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[1-2][0-9]|3[0-2])\b' | \
        while read -r cidr; do
            # 验证 IP 每段 <= 255
            valid=true
            ip_part="${cidr%/*}"
            IFS='.' read -ra octets <<< "$ip_part"
            for octet in "${octets[@]}"; do
                if ! [[ "$octet" =~ ^[0-9]+$ ]] || [ "$octet" -gt 255 ] || [ "$octet" -lt 0 ]; then
                    valid=false
                    break
                fi
            done
            if [[ "$valid" == true ]]; then
                echo "$cidr" >> "$TEMP_IP_LIST"
                echo "  - $cidr" >> "$output_yaml"
            fi
        done
    done < "$filepath"
}

export -f process_file
export OUTPUT_DIR
export TEMP_IP_LIST

# ========== 安全并行处理（支持空格、中文、特殊字符）==========
if [[ "$USE_PARALLEL" == true ]]; then
    # 创建临时任务列表（用 NUL 分隔）
    for i in "${!file_list[@]}"; do
        printf "%d\0%d\0%s\0" "$((i+1))" "$total_files" "${file_list[i]}"
    done | \
    parallel -0 -n3 --joblog /dev/stderr 'process_file {1} {2} {3}'
else
    # 单线程回退
    current=0
    for filepath in "${file_list[@]}"; do
        ((current++))
        process_file "$filepath" "$total_files" "$current"
    done
fi

# ========== 合并去重与生成最终 YAML ==========
echo "🔧 正在对所有 CIDR 地址进行排序、去重并生成最终配置..."

# 去重 + 排序
sort -u "$TEMP_IP_LIST" > "${TEMP_IP_LIST}.uniq"

# 生成最终 YAML 文件
{
    echo "payload:"
    while read -r cidr; do
        echo "  - $cidr"
    done < "${TEMP_IP_LIST}.uniq"
} > "$MERGED_YAML"

# 统计
unique_count=$(wc -l < "${TEMP_IP_LIST}.uniq")

# 完成提示
echo "✅ 成功生成:"
echo "   - 分文件目录: $OUTPUT_DIR/"
echo "   - 合并结果:   $MERGED_YAML"
echo "🎉 共处理 $total_files 个文件，合并了 $unique_count 个唯一 CIDR 地址（已去重）。"