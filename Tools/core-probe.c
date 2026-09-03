// Headless probe: dlopen the core and print what it advertises.
#include <stdio.h>
#include <string.h>
#include <stdbool.h>
#include <dlfcn.h>

struct retro_controller_description { const char *desc; unsigned id; };
struct retro_controller_info { const struct retro_controller_description *types; unsigned num_types; };
struct retro_variable { const char *key; const char *value; };

static bool env_cb(unsigned cmd, void *data) {
    unsigned base = cmd & ~0x10000u;
    if (base == 35 && data) {                 // SET_CONTROLLER_INFO
        const struct retro_controller_info *info = data;
        for (unsigned port = 0; info[port].types; port++) {
            printf("port %u:\n", port);
            for (unsigned i = 0; i < info[port].num_types; i++)
                printf("    id %5u (0x%04x)  %s\n",
                       info[port].types[i].id, info[port].types[i].id,
                       info[port].types[i].desc ? info[port].types[i].desc : "?");
            if (port >= 1) break;
        }
        return true;
    }
    if (base == 16 && data) {                 // SET_VARIABLES
        const struct retro_variable *v = data;
        printf("\n--- core options (key => default) ---\n");
        for (; v->key; v++) {
            if (!strstr(v->key, "memcard") && !strstr(v->key, "pad")) continue;
            printf("  %s\n     %.140s\n", v->key, v->value ? v->value : "");
        }
        return true;
    }
    if (base == 52 && data) { *(unsigned *)data = 0; return true; }  // options v0
    return false;
}

int main(int argc, char **argv) {
    void *h = dlopen(argv[1], RTLD_LAZY | RTLD_LOCAL);
    if (!h) { printf("dlopen failed: %s\n", dlerror()); return 1; }
    void (*set_env)(bool (*)(unsigned, void *)) = dlsym(h, "retro_set_environment");
    void (*core_init)(void) = dlsym(h, "retro_init");
    printf("--- controller types ---\n");
    set_env(env_cb);
    core_init();
    return 0;
}
