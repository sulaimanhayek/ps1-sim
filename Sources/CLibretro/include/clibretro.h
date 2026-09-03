// Minimal libretro ABI surface needed by PS1Sim, plus a varargs log shim
// that Swift cannot express directly.
#ifndef PS1SIM_CLIBRETRO_H
#define PS1SIM_CLIBRETRO_H

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

struct retro_game_info {
    const char *path;
    const void *data;
    size_t      size;
    const char *meta;
};

struct retro_game_geometry {
    unsigned base_width;
    unsigned base_height;
    unsigned max_width;
    unsigned max_height;
    float    aspect_ratio;
};

struct retro_system_timing {
    double fps;
    double sample_rate;
};

struct retro_system_av_info {
    struct retro_game_geometry geometry;
    struct retro_system_timing timing;
};

struct retro_system_info {
    const char *library_name;
    const char *library_version;
    const char *valid_extensions;
    bool        need_fullpath;
    bool        block_extract;
};

struct retro_variable {
    const char *key;
    const char *value;
};

// The real struct holds a variadic function pointer. Swift cannot form one, so
// we type it as a raw pointer and fill it with ps1sim_log_printf below; the ABI
// is identical.
struct retro_log_callback {
    void *log;
};

struct retro_message {
    const char *msg;
    unsigned    frames;
};

typedef void (*ps1sim_log_sink_t)(int level, const char *msg);

/// Install the Swift-side receiver for core log lines.
void ps1sim_set_log_sink(ps1sim_log_sink_t sink);

/// Variadic entry point handed to the core as retro_log_callback.log.
void ps1sim_log_printf(int level, const char *fmt, ...);

/// Address of ps1sim_log_printf. Swift cannot reference a variadic C function
/// directly, so it asks C for the pointer.
void *ps1sim_log_function(void);

#endif
