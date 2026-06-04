#!/usr/bin/env bash
  set -euo pipefail

  # 用法:
  #   bash disk_speed_test.sh [挂载路径] [测试文件大小GiB] [轮数]
  # 例子:
  #   bash disk_speed_test.sh /Volumes/data 8 3

  TARGET="${1:-/Volumes/data}"
  SIZE_GIB="${2:-8}"
  RUNS="${3:-3}"
  COUNT_MB=$((SIZE_GIB * 1024))
  TEST_FILE="${TARGET}/.speedtest.$$\.bin"

  if [[ ! -d "$TARGET" ]]; then
    echo "错误: 目录不存在 -> $TARGET"
    exit 1
  fi
  if [[ ! -w "$TARGET" ]]; then
    echo "错误: 目录不可写 -> $TARGET"
    exit 1
  fi
  if ! [[ "$SIZE_GIB" =~ ^[0-9]+$ && "$RUNS" =~ ^[0-9]+$ && "$SIZE_GIB" -gt 0 && "$RUNS" -gt 0 ]]; then
    echo "错误: 大小和轮数必须是正整数"
    exit 1
  fi

  cleanup() {
    rm -f "$TEST_FILE" 2>/dev/null || true
  }
  trap cleanup EXIT

  parse_secs() {
    sed -E 's/.* in ([0-9.]+) secs.*/\1/'
  }

  parse_bps() {
    awk -F'[()]' '/bytes transferred/ {print $2}' | awk '{print $1}'
  }

  bps_to_mbs() {
    awk -v bps="$1" 'BEGIN {printf "%.2f", bps/1048576}'
  }

  sum_write=0
  sum_read=0

  echo
  echo "=== 磁盘读写速度测试 ==="
  echo "目标路径 : $TARGET"
  echo "文件大小 : ${SIZE_GIB} GiB"
  echo "测试轮数 : $RUNS"
  echo

  printf "%-6s %-8s %-10s %-12s %-12s\n" "轮次" "类型" "大小(GiB)" "耗时(s)" "速度(MiB/s)"
  printf "%-6s %-8s %-10s %-12s %-12s\n" "----" "----" "---------" "-------" "-----------"

  for ((i=1; i<=RUNS; i++)); do
    # 写测试
    out_w=$(dd if=/dev/zero of="$TEST_FILE" bs=1m count="$COUNT_MB" conv=fsync 2>&1)
    secs_w=$(echo "$out_w" | parse_secs)
    bps_w=$(echo "$out_w" | parse_bps)
    mbs_w=$(bps_to_mbs "$bps_w")

    # 读测试（第二次读可能受缓存影响）
    out_r=$(dd if="$TEST_FILE" of=/dev/null bs=1m 2>&1)
    secs_r=$(echo "$out_r" | parse_secs)
    bps_r=$(echo "$out_r" | parse_bps)
    mbs_r=$(bps_to_mbs "$bps_r")

    printf "%-6s %-8s %-10s %-12s %-12s\n" "$i" "WRITE" "$SIZE_GIB" "$secs_w" "$mbs_w"
    printf "%-6s %-8s %-10s %-12s %-12s\n" "$i" "READ"  "$SIZE_GIB" "$secs_r" "$mbs_r"

    sum_write=$(awk -v a="$sum_write" -v b="$mbs_w" 'BEGIN {printf "%.6f", a+b}')
    sum_read=$(awk -v a="$sum_read" -v b="$mbs_r" 'BEGIN {printf "%.6f", a+b}')

    rm -f "$TEST_FILE"
  done

  avg_write=$(awk -v s="$sum_write" -v n="$RUNS" 'BEGIN {printf "%.2f", s/n}')
  avg_read=$(awk -v s="$sum_read" -v n="$RUNS" 'BEGIN {printf "%.2f", s/n}')

  echo
  echo "=== 汇总 ==="
  printf "%-12s %-12s\n" "平均写入" "${avg_write} MiB/s"
  printf "%-12s %-12s\n" "平均读取" "${avg_read} MiB/s"
  echo
  echo "提示: 如果测 NFS 性能，把目标路径改成 NFS 挂载点（如 ~/mnt/data）。"

  运行示例：

  bash disk_speed_test.sh /Volumes/data 8 3
