#!/bin/zsh
# ============================================================
# macbench-apple —— Apple Silicon (M1/M2/M3/M4) 电池性能对比跑分
# 由原型 macbench.sh 拆分而来,只针对 M 系列设计。
#
# 用法:
#   ./macbench-apple.sh                 正常跑分(约1分钟,含中文交互引导)
#   ./macbench-apple.sh --auto          跳过交互,直接跑(适合脚本调用)
#   ./macbench-apple.sh --quick         快速模式(约15秒,仅验证可用,分数不用于对比)
#   ./macbench-apple.sh --freq          额外用 sudo powermetrics 读各集群实际频率/功耗(需输密码)
#   ./macbench-apple.sh --sustain N     持续性能曲线时长改为 N 秒(默认 30,建议 60)
#   ./macbench-apple.sh compare 旧结果 新结果   对比两次跑分
#
# 设计要点(与 Intel 版的差异):
#   · 不依赖 hw.cpufrequency_max(Apple Silicon 不提供),改用 P/E 核心拓扑;
#   · 单核/全核测试设置 QoS=USER_INTERACTIVE,让调度器优先派发到性能核;
#   · 增加持续性能曲线:满载 N 秒按时间段统计吞吐量,区分
#     "一直被限速"和"跑久后因温度/功耗管理逐渐下降";
#   · CPU_Speed_Limit < 100 只作为"macOS 明确报告主动限速"的强证据,
#     该字段缺失或为 100 不能单独排除其他形式的频率管理。
# ============================================================
set -e

QUICK=0
FREQ=0
AUTO=0
SUSTAIN_SEC=30
args=()
for arg in "$@"; do
  case "$arg" in
    --quick) QUICK=1 ;;
    --freq)  FREQ=1 ;;
    --auto)  AUTO=1 ;;
    --sustain) : ;;          # 值在下一个参数取
    --sustain=*) SUSTAIN_SEC="${arg#--sustain=}" ;;
    *) args+=("$arg") ;;
  esac
done
# 处理 "--sustain N" 分离式参数(遍历位置参数取 --sustain 的下一个值)
n=1
for a in "$@"; do
  if [ "$a" = "--sustain" ] && [ $n -lt $# ]; then
    next=$((n+1))
    eval "SUSTAIN_SEC=\${$next}"
  fi
  n=$((n+1))
done
case "$SUSTAIN_SEC" in ''|*[!0-9]*) SUSTAIN_SEC=30 ;; esac
[ "$SUSTAIN_SEC" -lt 5 ] && SUSTAIN_SEC=5

# ---- compare 模式:对比两次结果 ----
if [ "${args[1]:-}" = "compare" ]; then
  OLD="${args[2]:-}"; NEW="${args[3]:-}"
  if [ ! -f "$OLD" ] || [ ! -f "$NEW" ]; then
    echo "用法: $0 compare 旧结果文件 新结果文件"; exit 1
  fi
  get() { grep "^$2=" "$1" 2>/dev/null | head -1 | cut -d= -f2-; }
  num() { case "$1" in ''|*[!0-9.]*) echo "0";; *) echo "$1";; esac; }
  echo "================ macbench-apple 对比结果 ================"
  printf "%-14s %12s %12s %12s\n" "项目" "第一次" "第二次" "比值(二/一)"
  echo "---------------------------------------------------"
  for key in SINGLE_SCORE MULTI_SCORE MEM_GBPS; do
    o=$(num "$(get "$OLD" "$key")"); n=$(num "$(get "$NEW" "$key")")
    r=$(awk "BEGIN{if ($o>0) printf \"%.2f\", $n/$o; else print \"-\"}")
    case "$key" in
      SINGLE_SCORE) name="单核分数" ;;
      MULTI_SCORE)  name="全核分数" ;;
      MEM_GBPS)     name="内存带宽" ;;
    esac
    printf "%-14s %12s %12s %12s\n" "$name" "$o" "$n" "$r"
  done
  o=$(num "$(get "$OLD" SUSTAIN_MIN_RATIO)"); n=$(num "$(get "$NEW" SUSTAIN_MIN_RATIO)")
  if [ "$o" != "0" ] && [ "$n" != "0" ]; then
    printf "%-14s %11s%% %11s%%\n" "持续曲线最低" "$o" "$n"
  fi
  echo "---------------------------------------------------"
  echo "第一次: $(get "$OLD" LABEL)  ($(get "$OLD" TIMESTAMP))"
  echo "第二次: $(get "$NEW" LABEL)  ($(get "$NEW" TIMESTAMP))"
  echo ""
  echo "解读:"
  echo "  · 比值 ≈ 0.50 → 第二次性能被限制了一半(典型无电池降频)"
  echo "  · 多核比值明显低于单核比值 → 睿频/高频档位被禁用或部分核心被限"
  echo "  · CPU_SPEED_LIMIT < 100 → 发现 macOS 明确报告主动限速,这是强证据"
  echo "  · CPU_SPEED_LIMIT = 100 或缺失 → 不能单独排除降频,"
  echo "    还要看 SUSTAIN_MIN_RATIO(持续曲线最低值)和 --freq 的实际频率"
  echo "  · 比值在 0.95~1.05 之间 → 建议视为噪声,不要据此下结论;"
  echo "    小幅差异(如 -6%)需要同状态连跑两次确认稳定后再判读"
  echo "  · 比值 ≈ 1.0 → 两次状态无差别"
  exit 0
fi

# ---- 架构守卫:只在 Apple Silicon 上运行 ----
BRAND=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "")
if ! echo "$BRAND" | grep -q "^Apple M"; then
  echo "本机不是 Apple Silicon Mac (brand_string: ${BRAND:-未知})。"
  echo "Intel Mac 请使用: ./macbench-intel.sh"
  exit 1
fi

# ---- 准备输出目录和临时目录 ----
OUTDIR="$(cd "$(dirname "$0")" && pwd)/results"
mkdir -p "$OUTDIR"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/macbench.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

echo "======================================"
echo "   macbench-apple 电池性能对比跑分 (Apple Silicon)"
echo "======================================"
echo ""

# ---- 收集系统信息:P/E 核心拓扑 ----
echo "[1/7] 收集系统信息"
MODEL=$(sysctl -n hw.model)
NCPU=$(sysctl -n hw.ncpu)
MEM=$(sysctl -n hw.memsize)
RAM_GB=$((MEM / 1073741824))
PCORE=$(sysctl -n hw.perflevel0.physicalcpu 2>/dev/null || echo "?")
ECORE=$(sysctl -n hw.perflevel1.physicalcpu 2>/dev/null || echo "0")
echo "    机型: $MODEL"
echo "    芯片: $BRAND"
if [ "$ECORE" != "0" ]; then
  echo "    CPU核心: $NCPU 核 = 性能核(P) $PCORE + 能效核(E) $ECORE"
else
  echo "    CPU核心: $NCPU 核 (拓扑未细分)"
fi
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
echo "[2/7] 检查电源状态"
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
  [ -z "$NOMINAL" ] && NOMINAL=$(battval AppleRawMaxCapacity)
  [ -z "$NOMINAL" ] && NOMINAL=$(battval FullChargeCapacity)
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

# ---- 限速状态 ----
echo "[3/7] 读取系统限速状态 (pmset -g therm)"
pmset -g therm | sed 's/^/    /' || true
SPEED_LIMIT=$(pmset -g therm | grep -i "CPU_Speed_Limit" | grep -oE '[0-9]+' | head -1)
LIMIT_REPORTED=1
if [ -z "$SPEED_LIMIT" ]; then
  SPEED_LIMIT=""
  LIMIT_REPORTED=0
  echo ""
  echo "    本机未报告 CPU_Speed_Limit 字段。"
  echo "    注意:这只说明 macOS 没有主动报告限速,不能排除"
  echo "    其他形式的功耗/温度/频率管理 —— 请看第 6 步的持续性能曲线。"
elif [ "$SPEED_LIMIT" -lt 100 ]; then
  echo ""
  echo "    ⚠️  发现 macOS 明确报告主动限速: CPU 只允许跑到 ${SPEED_LIMIT}% 的速度!"
  echo "       这是系统自我报告的直接证据,通常与电池故障/缺失有关。"
else
  echo ""
  echo "    CPU_Speed_Limit = ${SPEED_LIMIT}% (macOS 报告未主动限速;"
  echo "    同样不能单独排除其他形式的频率管理,以持续曲线和实际频率为准)"
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
echo "[4/7] 编译测试程序 (用系统自带 clang, 无需安装任何东西)"
cat > "$TMP/bench.c" <<'CEOF'
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <time.h>
#include <unistd.h>
#include <sys/qos.h>

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

struct run_arg {
    double budget_sec;
    double bucket_sec;    // >0 时按时间段统计吞吐量(持续曲线)
    uint64_t *buckets;    // 线程私有数组,主线程 join 后再汇总
    int nbuckets;
    uint64_t iters;
    uint64_t sink;
};

static void *runner(void *p) {
    struct run_arg *a = (struct run_arg *)p;
    double t0 = monotonic_sec();
    uint64_t done = 0;
    for (;;) {
        double e = monotonic_sec() - t0;
        if (e >= a->budget_sec) break;
        int b = -1;
        if (a->buckets) {
            b = (int)(e / a->bucket_sec);
            if (b >= a->nbuckets) b = a->nbuckets - 1;
        }
        workload(1000000, &a->sink);
        done += 1000000;
        if (b >= 0) a->buckets[b] += 1000000;
    }
    a->iters = done;
    return NULL;
}

static void set_p_core_qos(void) {
    // USER_INTERACTIVE 优先级让调度器把线程派发到性能核(P core)
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
}

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: bench single|multi|mem|sustain seconds [bucket_sec]\n");
        return 1;
    }
    double budget = atof(argv[2]);
    set_p_core_qos();

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

    int nthreads = (strcmp(argv[1], "single") == 0)
                 ? 1 : (int)sysconf(_SC_NPROCESSORS_ONLN);
    if (nthreads > 256) nthreads = 256;

    int sustain = (strcmp(argv[1], "sustain") == 0);
    double bucket_sec = 0;
    int nbuckets = 0;
    if (sustain && argc >= 4) {
        bucket_sec = atof(argv[3]);
        nbuckets = (int)(budget / bucket_sec);
        if (nbuckets < 1) nbuckets = 1;
    }

    pthread_t th[256];
    struct run_arg args[256];
    uint64_t *bucket_mem = NULL;
    if (sustain) {
        bucket_mem = calloc((size_t)nbuckets * (size_t)nthreads, sizeof(uint64_t));
        if (!bucket_mem) { fprintf(stderr, "calloc failed\n"); return 1; }
    }
    for (int i = 0; i < nthreads; i++) {
        args[i].budget_sec = budget;
        args[i].bucket_sec = bucket_sec;
        args[i].buckets = sustain ? bucket_mem + (size_t)i * (size_t)nbuckets : NULL;
        args[i].nbuckets = nbuckets;
        args[i].iters = 0;
        args[i].sink = 0;
        pthread_create(&th[i], NULL, runner, &args[i]);
    }
    uint64_t total = 0, sink_sum = 0;
    uint64_t *bsum = NULL;
    if (sustain) {
        bsum = calloc((size_t)nbuckets, sizeof(uint64_t));
        if (!bsum) { fprintf(stderr, "calloc failed\n"); return 1; }
    }
    for (int i = 0; i < nthreads; i++) {
        pthread_join(th[i], NULL);
        total += args[i].iters;
        sink_sum += args[i].sink;
        if (sustain) {
            for (int b = 0; b < nbuckets; b++) bsum[b] += args[i].buckets[b];
        }
    }
    printf("SINK=%llu\n", (unsigned long long)sink_sum);
    printf("TOTAL_ITERS=%llu\n", (unsigned long long)total);
    printf("NTHREADS=%d\n", nthreads);
    if (sustain) {
        printf("NB=%d\n", nbuckets);
        for (int b = 0; b < nbuckets; b++)
            printf("BUCKET=%d %llu\n", b, (unsigned long long)bsum[b]);
        free(bsum);
    }
    if (bucket_mem) free(bucket_mem);
    return 0;
}
CEOF
cc -O2 -o "$TMP/bench" "$TMP/bench.c" -lpthread
echo "    编译完成"
echo ""

# ---- 跑分 ----
TIME_SEC=3
SUSTAIN_BUCKET=10
if [ $QUICK -eq 1 ]; then
  TIME_SEC=1
  SUSTAIN_SEC=6
  SUSTAIN_BUCKET=1
  echo "(快速模式: 每项只测1秒、持续曲线6秒,分数仅用于验证,不要用于对比)"
  echo ""
fi
echo "[5/7] 开始跑分 (单核 ${TIME_SEC}s → 全核 ${TIME_SEC}s → 内存 ${TIME_SEC}s)"
echo "      测试期间请不要操作电脑、不要运行其他程序。"
echo ""
echo "      ▶ 单核测试中..."
SINGLE_OUT=$("$TMP/bench" single "$TIME_SEC")
echo "      ▶ 全核测试中..."
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
echo "    │ 全核分数 : $MULTI_SCORE  (并行效率 x$MULTI_RATIO)"
echo "    │ 内存带宽 : $MEM_GBPS GB/s"
echo "    └─────────────────────────────────────────┘"
echo ""

# ---- 持续性能曲线 ----
echo "[6/7] 持续性能曲线 (全核满载 ${SUSTAIN_SEC}s,每 ${SUSTAIN_BUCKET}s 一段)"
echo "      这一步时间最长,期间请勿操作电脑。"
SUSTAIN_OUT=$("$TMP/bench" sustain "$SUSTAIN_SEC" "$SUSTAIN_BUCKET")
NB=$(echo "$SUSTAIN_OUT" | grep '^NB=' | cut -d= -f2)
NB=$(numck "$NB")
BASE_ITERS=""
SUSTAIN_LINES=""
MIN_PCT=100
END_PCT=100
if [ "$NB" -ge 2 ]; then
  echo ""
  echo "    时间段        全核吞吐量(相对第一段)"
  for ((b=0; b<NB; b++)); do
    V=$(echo "$SUSTAIN_OUT" | grep "^BUCKET=$b " | cut -d' ' -f2)
    V=$(numck "$V")
    PCT=0
    if [ -z "$BASE_ITERS" ]; then
      BASE_ITERS=$V
      PCT=100
    else
      PCT=$(awk "BEGIN{if ($BASE_ITERS>0) printf \"%.0f\", $V/$BASE_ITERS*100; else print 0}")
    fi
    T0=$((b * SUSTAIN_BUCKET)); T1=$(((b+1) * SUSTAIN_BUCKET))
    printf "    %3ds-%3ds      %s%%\n" "$T0" "$T1" "$PCT"
    SUSTAIN_LINES="$SUSTAIN_LINES SUSTAIN_${T0}s=${PCT}"
    if [ "$b" -gt 0 ] && [ "$PCT" -lt "$MIN_PCT" ]; then MIN_PCT=$PCT; fi
    END_PCT=$PCT
  done
  echo ""
  if [ "$MIN_PCT" -ge 95 ]; then
    echo "    解读: 曲线基本持平 (最低 ${MIN_PCT}%) → 本机持续满载性能稳定,"
    echo "          没有观察到因温度/功耗导致的明显衰减。"
  elif [ "$MIN_PCT" -ge 80 ]; then
    echo "    解读: 曲线有轻度下降 (最低 ${MIN_PCT}%) → 存在温和的温度/功耗管理,"
    echo "          属于多数 Mac 的正常表现。"
  else
    echo "    解读: 曲线明显下滑 (最低 ${MIN_PCT}%) → 满载时性能被显著管理。"
    echo "          如果此时 CPU_Speed_Limit=100,说明是频率层面的隐性调节,"
    echo "          可用 --freq 看实际频率进一步确认。"
  fi
else
  echo "    (时长太短,未生成曲线)"
fi
echo ""

# ---- 可选:读实际频率/功耗 ----
FREQ_LINES=""
if [ $FREQ -eq 1 ]; then
  echo "[额外] 读取各集群实际频率与功耗 (powermetrics, 需要 sudo 密码)"
  PM_OUT=$(sudo powermetrics -n 1 -i 500 --samplers cpu_power 2>/dev/null || true)
  echo "$PM_OUT" | grep -E "(E|P).*Cluster HW active frequency" | head -8 | sed 's/^/    /'
  echo "$PM_OUT" | grep -E "^CPU Power" | head -2 | sed 's/^/    /'
  FREQ_LINES=$(echo "$PM_OUT" | grep -E "(E|P).*Cluster HW active frequency" | head -4 | tr '\n' '|' || true)
  echo ""
fi

# ---- 写结果文件 ----
STAMP="$(date +%Y%m%d_%H%M%S)"
OUT="$OUTDIR/result_$STAMP.txt"
TS=$(date "+%Y-%m-%d %H:%M:%S")
{
  echo "# macbench-apple 结果"
  echo "TIMESTAMP=$TS"
  echo "LABEL=$LABEL"
  echo "MODEL=$MODEL"
  echo "CHIP=$BRAND"
  echo "NCPU=$NCPU"
  echo "PCORES=$PCORE"
  echo "ECORES=$ECORE"
  echo "RAM_GB=$RAM_GB"
  echo "POWER=$POWER_DESC"
  echo "CPU_SPEED_LIMIT=${SPEED_LIMIT:-未报告}"
  echo "BATTERY_STATUS=$BATT_LINE"
  [ -n "$BATTERY_HEALTH" ] && echo "BATTERY_HEALTH_PCT=$BATTERY_HEALTH"
  echo "SINGLE_SCORE=$SINGLE_SCORE"
  echo "MULTI_SCORE=$MULTI_SCORE"
  echo "MEM_GBPS=$MEM_GBPS"
  echo "SUSTAIN_SEC=$SUSTAIN_SEC"
  echo "SUSTAIN_BUCKET=$SUSTAIN_BUCKET"
  echo "SUSTAIN_MIN_RATIO=$MIN_PCT"
  echo "SUSTAIN_END_RATIO=$END_PCT"
  [ -n "$SUSTAIN_LINES" ] && echo "$SUSTAIN_LINES" | sed 's/^ //'
  [ -n "$FREQ_LINES" ] && echo "PWRMETRICS=$FREQ_LINES"
} > "$OUT"

echo "[7/7] 完成! 结果已保存: $OUT"
echo ""
echo "┌─────────────── 接下来怎么做 ───────────────┐"
echo "│ 1. 换电池/恢复后,在同样的条件下再跑一次     │"
echo "│ 2. 用下面的命令对比两次结果:               │"
echo "│                                            │"
echo "│    $0 compare \\"
echo "│        $OUT 新结果文件"
echo "│                                            │"
echo "│ 3. 判读: 比值≈0.5 → 性能被限制一半;        │"
echo "│    CPU_SPEED_LIMIT<100 → 强证据;           │"
echo "│    但 =100 时还要看 SUSTAIN_MIN_RATIO      │"
echo "└────────────────────────────────────────────┘"
