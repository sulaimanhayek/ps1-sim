#include "include/clibretro.h"
#include <stdarg.h>
#include <stdio.h>

static ps1sim_log_sink_t g_sink = NULL;

void ps1sim_set_log_sink(ps1sim_log_sink_t sink) { g_sink = sink; }

void ps1sim_log_printf(int level, const char *fmt, ...) {
    if (!g_sink || !fmt) return;
    char buf[2048];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    g_sink(level, buf);
}
