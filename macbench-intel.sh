#!/bin/zsh
# ============================================================
# macbench-intel —— Intel Mac 电池性能对比跑分
# 由原型 macbench.sh 拆分而来,只针对 Intel 设计。
#
# 用法:
#   ./macbench-intel.sh                 正常跑分(约30秒,含中文交互引导)
#   ./macbench-intel.sh --auto          跳过交互,直接跑(适合脚本调用)
#   ./macbench-intel.sh --quick         快速模式(约8秒,仅验证可用,分数不用于对比)
#   ./macbench-intel.sh --freq          额外用 sudo powermetrics 读实际CPU频率(需输密码)
#   ./macbench-intel.sh compare 旧结果 新结果   对比两次跑分
#
# 设计要点(与 Apple Silicon 版的差异):
#   · Intel 提供标称频率字段(hw.cpufrequency_max),可直接对照睿频判断降频;
#   · 读取 XCPM 热节流等级(machdep.xcpm.*_thermal_level),观测温控状态;
#   · Intel 的限速链路成熟:CPU_Speed_Limit 压低 → 实际频率下降 → 跑分下降,
#     三者可以直接互相对应验证。
# ============================================================
set -e

QUICK=0
FREQ=0
AUTO=0
args=()
for arg in "$@"; do
  case "$arg" in
    --quick) QUICK=1 ;;
    --freq)  FREQ=1 ;;
    --auto)  AUTO=1 ;;
    *) args+=("$arg") ;;
  esac
done

# ---- compare 模式:对比两次结果 ----
if [ "${args[1]:-}" = "compare" ]; then
  OLD="${args[2]:-}"; NEW="${args[3]:-}"
  if [ ! -f "$OLD" ] || [ ! -f "$NEW" ]; then
    echo "用法: $0 compare 旧结果文件 新结果文件"; exit 1
  fi
  get() { grep "^$2=" "$1" 2>/dev/null | head -1 | cut -d= -f2-; }
  num() { case "$1" in ''|*[!0-9.]*) echo "0";; *) echo "$1";; esac; }
  echo "================ macbench-intel 对比结果 ================"
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
  echo "  · 比值 ≈ 0.50 → 第二次性能被限制了一半(典型无电池降频)"
  echo "  · 多核比值明显低于单核比值 → 睿频被禁用或核心被砍"
  echo "  · CPU_SPEED_LIMIT < 100 → 发现 macOS 明确报告主动限速,这是强证据;"
  echo "    配合 --freq 的实际频率,可以验证「限速 → 频率下降 → 分数下降」"
  echo "  · 比值在 0.95~1.05 之间 → 建议视为噪声,不要据此下结论;"
  echo "    小幅差异(如 -6%)需要同状态连跑两次确认稳定后再判读"
  echo "  · 比值 ≈ 1.0 → 两次状态无差别"
  exit 0
fi

# ---- 架构守卫:只在 Intel Mac 上运行 ----
BRAND=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "")
if echo "$BRAND" | grep -q "^Apple M"; then
  echo "本机是 Apple Silicon ($BRAND)。"
  echo "M1/M2/M3/M4 请使用: ./macbench-apple.sh"
  exit 1
fi

# ---- 准备输出目录和临时目录 ----
OUTDIR="$(cd "$(dirname "$0")" && pwd)/results"
mkdir -p "$OUTDIR"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/macbench.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

echo "======================================"
echo "   macbench-intel 电池性能对比跑分 (Intel)"
echo "======================================"
echo ""

# ---- 收集系统信息 ----
echo "[1/6] 收集系统信息"
MODEL=$(sysctl -n hw.model)
NCPU=$(sysctl -n hw.ncpu)
MEM=$(sysctl -n hw.memsize)
RAM_GB=$((MEM / 1073741824))
FREQ_MAX=$(sysctl -n hw.cpufrequency_max 2>/dev/null || echo "")
if [ -n "$FREQ_MAX" ]; then
  FREQ_MAX_MHZ=$((FREQ_MAX / 1000000))
  echo "    标称最高频率: ${FREQ_MAX_MHZ} MHz (睿频判断基准)"
else
  echo "    标称最高频率: 本机不提供 hw.cpufrequency_max,请用 --freq 看实际频率"
fi
echo "    机型: $MODEL"
echo "    芯片: $BRAND"
echo "    CPU核心数: $NCPU"
echo "    内存: ${RAM_GB} GB"
echo ""

# ---- 负载检查:后台忙时跑分会失真 ----
LOAD1=$(sysctl -n vm.loadavg 2>/dev/null | awk '{gsub("[{}]",""); print $2}')
case "$LOAD1" in ''|*[!0-9.]*) LOAD1=0;; esac
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
# 从 ioreg 输出取数值:顶层是 "Key" = N,BatteryData 里是 "Key"=N,两种都试
battval() {
  v=$(echo "$SMART" | grep -oE "\"$1\" = [0-9]+" | head -1 | grep -oE '[0-9]+$' || true)
  [ -z "$v" ] && v=$(echo "$SMART" | grep -oE "\"$1\"=[0-9]+" | head -1 | grep -oE '[0-9]+$' || true)
  echo "$v"
}
BATTERY_HEALTH=""
if [ -n "$SMART" ]; then
  echo "$SMART" | grep -E '"(ExternalConnected|FullyCharged|CycleCount)"' | sed 's/^/    /' || true
  NOMINAL=$(battval NominalChargeCapacity)
  [ -z "$NOMINAL" ] && NOMINAL=$(battval MaxCapacity)
  DESIGN=$(battval DesignCapacity)
  if [ -n "$NOMINAL" ] && [ -n "$DESIGN" ] && [ "$DESIGN" -gt 0 ]; then
    BATTERY_HEALTH=$(awk "BEGIN{printf \"%.0f\", $NOMINAL / $DESIGN * 100}")
    echo "    当前满电容量/设计容量: $NOMINAL / $DESIGN (电池健康度约 ${BATTERY_HEALTH}%)"
  fi
  PERM_FAIL=$(echo "$SMART" | grep -c '"PermanentFailureStatus" = 1' || true)
  if [ "$PERM_FAIL" != "0" ]; then
    echo "    ⚠️  系统报告:电池永久故障 (PermanentFailureStatus = 1)"
  fi
fi
echo ""

# ---- 限速状态与热节流等级 ----
echo "[3/6] 读取系统限速状态 (pmset -g therm)"
pmset -g therm | sed 's/^/    /' || true
SPEED_LIMIT=$(pmset -g therm | grep -i "CPU_Speed_Limit" | grep -oE '[0-9]+' | head -1)
LIMIT_REPORTED=1
if [ -z "$SPEED_LIMIT" ]; then
  SPEED_LIMIT=""
  LIMIT_REPORTED=0
  echo ""
  echo "    本机未报告 CPU_Speed_Limit 字段,不能据此排除降频,"
  echo "    请结合 --freq 的实际频率判断。"
elif [ "$SPEED_LIMIT" -lt 100 ]; then
  echo ""
  echo "    ⚠️  发现 macOS 明确报告主动限速: CPU 只允许跑到 ${SPEED_LIMIT}% 的速度!"
  echo "       这是系统自我报告的直接证据,通常与电池故障/缺失有关。"
else
  echo ""
  echo "    CPU_Speed_Limit = ${SPEED_LIMIT}% (macOS 报告未主动限速)"
fi

# Intel 专属:XCPM 热节流等级(非0表示有热压力;只观测,不用于定论)
CPU_THERM=$(sysctl -n machdep.xcpm.cpu_thermal_level 2>/dev/null || echo "?")
IO_THERM=$(sysctl -n machdep.xcpm.io_thermal_level 2>/dev/null || echo "?")
if [ "$CPU_THERM" != "?" ]; then
  echo "    XCPM 热节流等级: CPU=$CPU_THERM, IO=$IO_THERM (0 = 无热压力)"
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

// 混合整数+浮点负载,结果写进线程私有的 sink,防止被编译器优化掉。
// 注意:每个线程只写自己的 arg->sink,不共享,避免 data race。
static void workload(uint64_t iterations, uint64_t *sink) {
    double x = 0.5;
    uint32_t h = 2166136261u;
    for (uint64_t i = 0; i < iterations; i++) {
        x = x * 1.0000001 + 0.0000001;
        if (x > 1.0) x -= 1.0;
        h = (h ^ (h << 13)) * 2654435761u;
        h ^= h >> 17;
        x += (double)(h & 0xff) * 1e-12;
    }
    *sink = (uint64_t)(x * 1e9) + h;
}

struct run_arg { double budget_sec; uint64_t iters; uint64_t sink; };

static void *runner(void *p) {
    struct run_arg *a = (struct run_arg *)p;
    double t0 = monotonic_sec();
    uint64_t done = 0;
    while (monotonic_sec() - t0 < a->budget_sec) {
        workload(1000000, &a->sink);
        done += 1000000;
    }
    a->iters = done;
    return NULL;
}

int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "usage: bench single|multi|mem seconds\n"); return 1; }
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
        args[i].sink = 0;
        pthread_create(&th[i], NULL, runner, &args[i]);
    }
    uint64_t total = 0, sink_sum = 0;
    for (int i = 0; i < nthreads; i++) {
        pthread_join(th[i], NULL);
        total += args[i].iters;
        sink_sum += args[i].sink;
    }
    printf("SINK=%llu\n", (unsigned long long)sink_sum);
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
  if [ -n "$FREQ_MAX" ]; then
    echo "    (对照: 标称最高 ${FREQ_MAX_MHZ} MHz,满载实测明显更低 = 存在降频)"
  fi
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
  echo "# macbench-intel 结果"
  echo "TIMESTAMP=$TS"
  echo "LABEL=$LABEL"
  echo "MODEL=$MODEL"
  echo "CHIP=$BRAND"
  echo "NCPU=$NCPU"
  echo "RAM_GB=$RAM_GB"
  echo "POWER=$POWER_DESC"
  echo "CPU_SPEED_LIMIT=${SPEED_LIMIT:-未报告}"
  [ "$CPU_THERM" != "?" ] && echo "XCPM_CPU_THERMAL_LEVEL=$CPU_THERM"
  [ "$IO_THERM" != "?" ] && echo "XCPM_IO_THERMAL_LEVEL=$IO_THERM"
  echo "BATTERY_STATUS=$BATT_LINE"
  [ -n "$BATTERY_HEALTH" ] && echo "BATTERY_HEALTH_PCT=$BATTERY_HEALTH"
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
echo "│ 3. 判读: 比值≈0.5 → 性能被限制一半;        │"
echo "│    CPU_SPEED_LIMIT<100 → 强证据,           │"
echo "│    配合 --freq 验证「限速→频率降→分数降」   │"
echo "└────────────────────────────────────────────┘"
