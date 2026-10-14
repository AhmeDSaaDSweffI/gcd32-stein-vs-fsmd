/*
 * main.c : bare-metal test of the gcd32 AXI4-Lite accelerator (Zybo Z7-20)
 *
 * Runs on ps7_cortexa9_0 (standalone BSP). Output goes to stdout, which is
 * PS UART1 (MIO 48/49), 115200 8N1.
 *
 *   1. Check the ID register (confirms the bitstream and AXI path)
 *   2. Directed test vectors with known results and the core latency
 *   3. Random regression against a software Euclid reference
 *   4. Time per call, hardware vs software
 *
 * The last line is "ALL TESTS PASSED" or "TESTS FAILED" (run_all.sh looks
 * for these).
 */

#include "xil_io.h"
#include "xil_printf.h"
#include "xil_types.h"
#include "xstatus.h"
#include "xtime_l.h"

/* AXI base address of gcd32_axi; fixed by build_hw.tcl (gcd_base) */
#define GCD_BASEADDR        0x43C00000U

/* Register offsets (see gcd32_axi.v) */
#define GCD_REG_CTRL        0x00U
#define GCD_REG_STATUS      0x04U
#define GCD_REG_A           0x08U
#define GCD_REG_B           0x0CU
#define GCD_REG_RESULT      0x10U
#define GCD_REG_CYCLES      0x14U
#define GCD_REG_ID          0x18U

#define GCD_CTRL_START      0x1U
#define GCD_STATUS_BUSY     0x1U
#define GCD_STATUS_DONE     0x2U
#define GCD_ID_VALUE        0x47434431U     /* "GCD1" */

/* The core needs at most 66 PL cycles, far fewer than one poll per cycle */
#define GCD_POLL_LIMIT      1000U

#define NUM_RANDOM          10000U
#define NUM_TIMED           10000U

static inline void gcd_write(u32 offset, u32 value)
{
    Xil_Out32(GCD_BASEADDR + offset, value);
}

static inline u32 gcd_read(u32 offset)
{
    return Xil_In32(GCD_BASEADDR + offset);
}

/*
 * Compute gcd(a, b) on the PL: write operands, pulse START, poll DONE.
 * cycles (optional) receives the core latency in PL clock cycles.
 * Returns XST_SUCCESS, or XST_FAILURE (result 0) if DONE never comes.
 */
static int gcd_hw(u32 a, u32 b, u32 *result, u32 *cycles)
{
    u32 polls = 0U;

    gcd_write(GCD_REG_A, a);
    gcd_write(GCD_REG_B, b);
    gcd_write(GCD_REG_CTRL, GCD_CTRL_START);

    while ((gcd_read(GCD_REG_STATUS) & GCD_STATUS_DONE) == 0U) {
        if (++polls >= GCD_POLL_LIMIT) {
            *result = 0U;
            return XST_FAILURE;
        }
    }

    *result = gcd_read(GCD_REG_RESULT);
    if (cycles != NULL) {
        *cycles = gcd_read(GCD_REG_CYCLES);
    }
    return XST_SUCCESS;
}

/* Software reference: Euclid with modulo */
static u32 gcd_sw(u32 a, u32 b)
{
    while (b != 0U) {
        u32 t = a % b;
        a = b;
        b = t;
    }
    return a;
}

/* xorshift32 pseudo-random generator */
static u32 rng_state = 0x2545F491U;

static u32 rng_next(void)
{
    u32 x = rng_state;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    rng_state = x;
    return x;
}

/* Mix of operand shapes: plain random, many shared factors of 2, large common factor */
static void random_pair(u32 i, u32 *a, u32 *b)
{
    u32 g;

    switch (i % 3U) {
    case 0U:
        *a = rng_next();
        *b = rng_next();
        break;
    case 1U:
        *a = rng_next() & 0xFFFF0000U;
        *b = rng_next() & 0xFFFFF000U;
        break;
    default:
        g  = (rng_next() & 0xFFFFU) | 1U;
        *a = g * (rng_next() & 0xFFFFU);
        *b = g * (rng_next() & 0x7FFFU);
        break;
    }
}

static u32 elapsed_ns(XTime t0, XTime t1, u32 count)
{
    return (u32)(((t1 - t0) * 1000000000ULL) / ((u64)COUNTS_PER_SECOND * count));
}

typedef struct {
    u32 a;
    u32 b;
    u32 expected;
} gcd_vector;

static const gcd_vector directed[] = {
    {14U,          161U,         7U},
    {161U,         14U,          7U},
    {0U,           0U,           0U},
    {0U,           12345U,       12345U},
    {98765U,       0U,           98765U},
    {42U,          42U,          42U},
    {1U,           1U,           1U},
    {48U,          180U,         12U},
    {1071U,        462U,         21U},
    {360U,         1001U,        1U},
    {111546435U,   5311488U,     5187U},
    {0x80000000U,  0x40000000U,  0x40000000U},
    {0x80000000U,  0x00300000U,  0x00100000U},
    {0xFFFFFFFFU,  1U,           1U},
    {0xFFFFFFFFU,  0xFFFFFFFEU,  1U},
    {0xFFFFFFFFU,  0xFFFFFFFFU,  0xFFFFFFFFU},
    {2971215073U,  1836311903U,  1U},      /* consecutive Fibonacci numbers */
    {4294967291U,  4294967279U,  1U},      /* two largest 32-bit primes */
};

#define NUM_DIRECTED (sizeof(directed) / sizeof(directed[0]))

int main(void)
{
    u32 i, a, b, hw, sw, cycles, id;
    u32 failures = 0U, mismatches = 0U;
    volatile u32 sink = 0U;
    XTime t0, t1;
    u32 hw_ns, sw_ns;

    xil_printf("\r\n==== gcd32 AXI accelerator test (Zybo Z7-20) ====\r\n");

    id = gcd_read(GCD_REG_ID);
    xil_printf("GCD core at 0x%08x, ID = 0x%08x\r\n", GCD_BASEADDR, id);
    if (id != GCD_ID_VALUE) {
        xil_printf("ERROR: unexpected ID (expected 0x%08x). Is the bitstream loaded?\r\n",
                   GCD_ID_VALUE);
        xil_printf("TESTS FAILED\r\n");
        return XST_FAILURE;
    }

    /* 1. Directed tests */
    xil_printf("\r\n-- Directed tests --\r\n");
    for (i = 0U; i < NUM_DIRECTED; i++) {
        a = directed[i].a;
        b = directed[i].b;
        if (gcd_hw(a, b, &hw, &cycles) != XST_SUCCESS) {
            xil_printf("  gcd(%u, %u): TIMEOUT\r\n", a, b);
            failures++;
            continue;
        }
        xil_printf("  gcd(%u, %u) = %u  [%u cycles]  %s\r\n", a, b, hw, cycles,
                   (hw == directed[i].expected) ? "PASS" : "FAIL");
        if (hw != directed[i].expected) {
            xil_printf("    expected %u\r\n", directed[i].expected);
            failures++;
        }
    }

    /* 2. Random regression against software */
    xil_printf("\r\n-- Random regression: %u vectors vs software --\r\n", NUM_RANDOM);
    for (i = 0U; i < NUM_RANDOM; i++) {
        random_pair(i, &a, &b);
        sw = gcd_sw(a, b);
        if (gcd_hw(a, b, &hw, NULL) != XST_SUCCESS || hw != sw) {
            if (mismatches < 10U) {
                xil_printf("  MISMATCH gcd(%u, %u): hw %u, sw %u\r\n", a, b, hw, sw);
            }
            mismatches++;
        }
    }
    xil_printf("  %u mismatches\r\n", mismatches);
    failures += mismatches;

    /* 3. Time per call (same operand sequence for both) */
    rng_state = 0x2545F491U;
    XTime_GetTime(&t0);
    for (i = 0U; i < NUM_TIMED; i++) {
        random_pair(i, &a, &b);
        (void)gcd_hw(a, b, &hw, NULL);
        sink += hw;
    }
    XTime_GetTime(&t1);
    hw_ns = elapsed_ns(t0, t1, NUM_TIMED);

    rng_state = 0x2545F491U;
    XTime_GetTime(&t0);
    for (i = 0U; i < NUM_TIMED; i++) {
        random_pair(i, &a, &b);
        sink += gcd_sw(a, b);
    }
    XTime_GetTime(&t1);
    sw_ns = elapsed_ns(t0, t1, NUM_TIMED);

    xil_printf("\r\n-- Time per call (%u calls, includes AXI register access) --\r\n",
               NUM_TIMED);
    xil_printf("  PL accelerator : %u ns\r\n", hw_ns);
    xil_printf("  ARM software   : %u ns\r\n", sw_ns);

    xil_printf("\r\n%u directed + %u random vectors, %u failures\r\n",
               (u32)NUM_DIRECTED, NUM_RANDOM, failures);
    xil_printf("%s\r\n", (failures == 0U) ? "ALL TESTS PASSED" : "TESTS FAILED");

    return (failures == 0U) ? XST_SUCCESS : XST_FAILURE;
}
