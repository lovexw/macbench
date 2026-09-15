#!/bin/zsh
# ============================================================
# macbench —— Mac 电池/无电池状态性能对比跑分
# 适用于 Intel 和 Apple Silicon (M1/M2/M3) 的 Mac
#
# 用法:
#   ./macbench.sh              正常跑分(约30秒,含中文交互引导)
#   ./macbench.sh --auto       跳过交互,直接跑(适合脚本调用)
#   ./macbench.sh --quick      快速模式(约8秒,仅验证可用,分数不用于对比)
#   ./macbench.sh --freq       额外用 sudo powermetrics 读实际CPU频率(需输密码)
#   ./macbench.sh compare 旧结果 新结果   对比两次跑分
#
# 原理:电池失效的 Mac 接电源时,macOS 可能通过 CPU_Speed_Limit
#       主动把 CPU 限速到 50% 甚至更低,并禁用睿频。
#       本脚本同时记录限速状态和实际计算性能,两次运行即可对比。
# ============================================================
set -e

QUICK=0
FREQ=0
AUTO=0
for arg in "$@"; do
  case "$arg" in
    --quick) QUICK=1 ;;
    --freq)  FREQ=1 ;;
    --auto)  AUTO=1 ;;
  esac
done

# ---- compare 模式:对比两次结果 ----
if [ "${1:-}" = "compare" ]; then
  OLD="${2:-}"; NEW="${3:-}"
  if [ ! -f "$OLD" ] || [ ! -f "$NEW" ]; then
    echo "用法: $0 compare 旧结果文件 新结果文件"; exit 1
  fi
  get() { grep "^$2=" "$1" 2>/dev/null | head -1 | cut -d= -f2-; }
  # 只允许数字,防止异常内容混进 awk 计算
  num() { case "$1" in ''|*[!0-9.]*) echo "0";; *) echo "$1";; esac; }
  echo "================ macbench 对比结果 ================"
  printf "%-14s %12s %12s %12s\n" "项目" "第一次" "第二次" "比值(二/一)"
  echo "---------------------------------------------------"
  for key in SINGLE_SCORE MULTI_SCORE MEM_GBPS; do
    o=$(num "$(get "$OLD" "$key")"); n=$(num "$(get "$NEW" "$key")")
    r=$(awk "BEGIN{if ($o>0) printf \"%.2f\", $n/$o; else print \"-\"}")
    case "$key" in
      SINGLE_SCORE) name="单核分数" ;;
      MULTI_SCORE)  name="多核分数" ;;
      MEM_GBPS)     name="内存带宽" ;;
    esac
    printf "%-14s %12s %12s %12s\n" "$name" "$o" "$n" "$r"
  done
  echo "---------------------------------------------------"
  echo "第一次: $(get "$OLD" LABEL)  ($(get "$OLD" TIMESTAMP))"
  echo "第二次: $(get "$NEW" LABEL)  ($(get "$NEW" TIMESTAMP))"
  echo ""
  echo "解读:"
  echo "  · 单核/多核比值 ≈ 0.50  → 第二次性能被限制了一半(典型无电池降频)"
  echo "  · 多核比值明显低于单核比值 → 睿频被禁用或核心被砍"
  echo "  · CPU_SPEED_LIMIT < 100 → 系统在主动限速,这是直接证据"
  echo "  · 比值 ≈ 1.0 → 两次状态无差别"
  exit 0
fi

# ---- 准备输出目录和临时目录 ----
OUTDIR="$(cd "$(dirname "$0")" && pwd)/results"
mkdir -p "$OUTDIR"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/macbench.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

echo "======================================"
echo "        macbench 电池性能对比跑分"
echo "======================================"
echo ""

# ---- 收集系统信息 ----
echo "[1/6] 收集系统信息"
MODEL=$(sysctl -n hw.model)
CHIP=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "未知")
NCPU=$(sysctl -n hw.ncpu)
MEM=$(sysctl -n hw.memsize)
RAM_GB=$((MEM / 1073741824))
NOMINAL_MAX=$(sysctl -n hw.cpufrequency_max 2>/dev/null || echo "")
if [ -z "$NOMINAL_MAX" ]; then
  NOMINAL_MAX="(Apple Silicon 不提供此值)"
fi
echo "    机型: $MODEL"
echo "    芯片: $CHIP"
echo "    CPU核心数: $NCPU"
echo "    内存: ${RAM_GB} GB"
echo "    标称最高频率: $NOMINAL_MAX"
echo ""

# ---- 负载检查:后台忙时跑分会失真 ----
LOAD1=$(sysctl -n vm.loadavg 2>/dev/null | awk '{gsub("[{}]",""); print $2}')
LOAD1=$(case "$LOAD1" in ''|*[!0-9.]*) echo 0;; *) echo "$LOAD1";; esac)
if [ "$AUTO" -eq 0 ]; then
  awk "BEGIN{exit !($LOAD1 > $NCPU * 0.7)}" && {
    echo "    ⚠️  注意: 当前系统负载较高 (1分钟平均负载 $LOAD1,核心数 $NCPU)"
    echo "       后台有程序在忙,跑分结果会偏低。建议关掉其他程序后再跑。"
  }
fi

# ---- 电源状态检查与交互确认 ----
echo "[2/6] 检查电源状态"
BATT_LINE=$(pmset -g batt | head -1)
echo "    $BATT_LINE"
if echo "$BATT_LINE" | grep -q "AC Power"; then
  POWER_DESC="AC(接通电源)"
else
  POWER_DESC="Battery(电池供电)"
  echo ""
  echo "    ⚠️  当前用的是电池供电,不是充电器!"
  if [ "$AUTO" -eq 0 ]; then
    printf "       这样测出来的是「电池供电」的性能。仍要继续吗? [y/N] "
    read -r ans
    case "$ans" in
      y|Y|yes|YES) : ;;
      *) echo "已取消。请插上充电器后重新运行。"; exit 0 ;;
    esac
  else
    echo "    (--auto 模式: 继续执行)"
  fi
fi
echo ""

# ---- 电池健康信息 ----
SMART=$(ioreg -rn AppleSmartBattery 2>/dev/null || true)
if [ -n "$SMART" ]; then
  echo "$SMART" | grep -E '"(ExternalConnected|FullyCharged|CycleCount|DesignCapacity|CurrentCapacity)"' | sed 's/^/    /' || true
  # PermanentFailureStatus=1 表示电池永久故障
  PERM_FAIL=$(echo "$SMART" | grep -c '"PermanentFailureStatus" = 1' || true)
  if [ "$PERM_FAIL" != "0" ]; then
    echo "    ⚠️  系统报告:电池永久故障 (PermanentFailureStatus = 1)"
  fi
fi
echo ""

# ---- 限速状态 ----
echo "[3/6] 读取系统限速状态 (pmset -g therm)"
pmset -g therm | sed 's/^/    /'
SPEED_LIMIT=$(pmset -g therm | grep -i "CPU_Speed_Limit" | grep -oE '[0-9]+' | head -1)
[ -z "$SPEED_LIMIT" ] && SPEED_LIMIT=100
if [ "$SPEED_LIMIT" -lt 100 ]; then
  echo ""
  echo "    ⚠️  检测到系统正在限速: CPU 只允许跑到 ${SPEED_LIMIT}% 的速度!"
  echo "       这通常就是「电池故障/缺失」导致的典型降频。"
else
  echo "    CPU_Speed_Limit = ${SPEED_LIMIT}% (未检测到主动限速)"
fi
echo ""

# ---- 交互:给这次测试命名 ----
LABEL="未命名"
if [ "$AUTO" -eq 0 ]; then
  printf "[交互] 请给这次测试起个名字(例如: 坏电池接电源 / 换新电池后),直接回车则用「未命名」: "
  read -r input_label
  [ -n "$input_label" ] && LABEL="$input_label"
fi

# ---- 编译测试程序 ----
echo "[4/6] 编译测试程序 (用系统自带 clang, 无需安装任何东西)"
cat > "$TMP/bench.c" <<'CEOF'
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <time.h>
#include <unistd.h>

static double monotonic_sec(void) {
    return (double)clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) / 1e9;
}

// 混合整数+浮点负载,结果参与返回值,防止被编译器优化掉
static uint64_t g_sink;
static void workload(uint64_t iterations) {
    double x = 0.5;
    uint32_t h = 2166136261u;
    for (uint64_t i = 0; i < iterations; i++) {
        x = x * 1.0000001 + 0.0000001;
        if (x > 1.0) x -= 1.0;
        h = (h ^ (h << 13)) * 2654435761u;
        h ^= h >> 17;
        x += (double)(h & 0xff) * 1e-12;
    }
    g_sink = (uint64_t)(x * 1e9) + h;
}

struct run_arg { double budget_sec; uint64_t iters; };

static void *runner(void *p) {
    struct run_arg *a = (struct run_arg *)p;
    double t0 = monotonic_sec();
    uint64_t done = 0;
    while (monotonic_sec() - t0 < a->budget_sec) {
        workload(1000000);
        done += 1000000;
    }
    a->iters = done;
    return NULL;
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: bench single|multi|mem seconds\n"); return 1; }
    double budget = atof(argv[2]);

    if (strcmp(argv[1], "mem") == 0) {
        static volatile uint64_t sink2;
        size_t sz = 256u << 20;  // 256 MB
        char *a = malloc(sz), *b = malloc(sz);
        if (!a || !b) { fprintf(stderr, "malloc failed\n"); return 1; }
        memset(a, 1, sz);
        double t0 = monotonic_sec();
        size_t total = 0;
        while (monotonic_sec() - t0 < budget) {
            // 每轮修改 a + 读取 b,防止编译器把 memcpy 优化掉
            a[total & (sz - 1)] ^= (char)total;
            memcpy(b, a, sz);
            sink2 += b[(total >> 12) & (sz - 1)];
            total += sz;
        }
        double sec = monotonic_sec() - t0;
        printf("MEM_SINK=%llu\n", (unsigned long long)sink2);
        printf("MEM_GBPS=%.2f\n", (double)total / sec / 1e9);
        return 0;
    }

    int nthreads = (strcmp(argv[1], "multi") == 0)
                 ? (int)sysconf(_SC_NPROCESSORS_ONLN) : 1;
    pthread_t th[256];
    struct run_arg args[256];
    if (nthreads > 256) nthreads = 256;
    for (int i = 0; i < nthreads; i++) {
        args[i].budget_sec = budget;
        args[i].iters = 0;
        pthread_create(&th[i], NULL, runner, &args[i]);
    }
    uint64_t total = 0;
    for (int i = 0; i < nthreads; i++) {
        pthread_join(th[i], NULL);
        total += args[i].iters;
    }
    printf("SINK=%llu\n", (unsigned long long)g_sink);
    printf("TOTAL_ITERS=%llu\n", (unsigned long long)total);
    printf("NTHREADS=%d\n", nthreads);
    return 0;
}
CEOF
cc -O2 -o "$TMP/bench" "$TMP/bench.c" -lpthread
echo "    编译完成"
echo ""

# ---- 跑分 ----
TIME_SEC=3
if [ $QUICK -eq 1 ]; then TIME_SEC=1; echo "(快速模式: 每项只测1秒,分数仅用于验证,不要用于对比)"; echo ""; fi
echo "[5/6] 开始跑分 (单核 ${TIME_SEC}s → 多核 ${TIME_SEC}s → 内存 ${TIME_SEC}s)"
echo "      测试期间请不要操作电脑、不要运行其他程序。"
echo ""
echo "      ▶ 单核测试中..."
SINGLE_OUT=$("$TMP/bench" single "$TIME_SEC")
echo "      ▶ 多核测试中..."
MULTI_OUT=$("$TMP/bench" multi "$TIME_SEC")
echo "      ▶ 内存带宽测试中..."
MEM_OUT=$("$TMP/bench" mem "$TIME_SEC")

SINGLE_ITERS=$(echo "$SINGLE_OUT" | grep TOTAL_ITERS | cut -d= -f2)
MULTI_ITERS=$(echo "$MULTI_OUT" | grep TOTAL_ITERS | cut -d= -f2)
MEM_GBPS=$(echo "$MEM_OUT" | grep MEM_GBPS | cut -d= -f2)
numck() { case "$1" in ''|*[!0-9.]*) echo "0";; *) echo "$1";; esac; }
SINGLE_ITERS=$(numck "$SINGLE_ITERS"); MULTI_ITERS=$(numck "$MULTI_ITERS"); MEM_GBPS=$(numck "$MEM_GBPS")

# 归一化分数:以"每秒1亿次迭代"为单位
SINGLE_SCORE=$(awk "BEGIN{printf \"%.1f\", $SINGLE_ITERS / 100000000 / $TIME_SEC * 100}")
MULTI_SCORE=$(awk "BEGIN{printf \"%.1f\", $MULTI_ITERS / 100000000 / $TIME_SEC * 100}")
MULTI_RATIO=$(awk "BEGIN{if ($SINGLE_SCORE>0) printf \"%.2f\", $MULTI_SCORE/$SINGLE_SCORE; else print 0}")

echo ""
echo "    ┌──────────────── 测试结果 ───────────────┐"
echo "    │ 单核分数 : $SINGLE_SCORE"
echo "    │ 多核分数 : $MULTI_SCORE  (并行效率 x$MULTI_RATIO)"
echo "    │ 内存带宽 : $MEM_GBPS GB/s"
echo "    └─────────────────────────────────────────┘"
echo ""

# ---- 可选:读实际频率 ----
FREQ_LINE=""
if [ $FREQ -eq 1 ]; then
  echo "[额外] 读取实际运行频率 (powermetrics, 需要 sudo 密码)"
  sudo powermetrics -n 1 -i 500 --samplers cpu_power 2>/dev/null | \
    grep "HW active frequency" | \
    awk -F': ' '{sum+=$2; n++} END{if(n>0) printf "    平均实际频率: %.0f MHz\n", sum/n; else print "    未能读取频率"}' | tee "$TMP/freq.txt"
  FREQ_LINE=$(grep "平均实际频率" "$TMP/freq.txt" | sed 's/^ *//' || true)
  echo ""
fi

# ---- 写结果文件 ----
STAMP="$(date +%Y%m%d_%H%M%S)"
OUT="$OUTDIR/result_$STAMP.txt"
TS=$(date "+%Y-%m-%d %H:%M:%S")
{
  echo "# macbench 结果"
  echo "TIMESTAMP=$TS"
  echo "LABEL=$LABEL"
  echo "MODEL=$MODEL"
  echo "CHIP=$CHIP"
  echo "NCPU=$NCPU"
  echo "RAM_GB=$RAM_GB"
  echo "POWER=$POWER_DESC"
  echo "CPU_SPEED_LIMIT=$SPEED_LIMIT"
  echo "BATTERY_STATUS=$BATT_LINE"
  echo "SINGLE_SCORE=$SINGLE_SCORE"
  echo "MULTI_SCORE=$MULTI_SCORE"
  echo "MEM_GBPS=$MEM_GBPS"
  [ -n "$FREQ_LINE" ] && echo "$FREQ_LINE"
} > "$OUT"

echo "[6/6] 完成! 结果已保存: $OUT"
echo ""
echo "┌─────────────── 接下来怎么做 ───────────────┐"
echo "│ 1. 换电池/恢复后,在同样的条件下再跑一次     │"
echo "│ 2. 用下面的命令对比两次结果:               │"
echo "│                                            │"
echo "│    $0 compare \\"
echo "│        $OUT 新结果文件"
echo "│                                            │"
echo "│ 3. 判读: 单核比值≈0.5 → 性能被限制一半;    │"
echo "│    CPU_SPEED_LIMIT<100 → 系统在主动限速     │"
echo "└────────────────────────────────────────────┘"