/* Make libtcod's SDL window Retina-aware.
 *
 * libtcod creates its SDL window internally without SDL_WINDOW_ALLOW_HIGHDPI,
 * so macOS renders the game at 1x and smooths it up 2x on Retina screens.
 * Loaded via DYLD_INSERT_LIBRARIES, this interposes SDL_CreateWindow and adds
 * the flag; libtcod then draws at full resolution with nearest-neighbour
 * scaling.
 *
 * Build: see build_shim.sh (x86_64, linked to tcod's bundled SDL2 by
 * absolute path so dyld reuses that same image when libtcod loads it).
 */
#include <stdint.h>

typedef struct SDL_Window SDL_Window;
extern SDL_Window *SDL_CreateWindow(const char *title, int x, int y, int w, int h, uint32_t flags);

#define SDL_WINDOW_ALLOW_HIGHDPI 0x00002000u

static SDL_Window *urr_CreateWindow(const char *title, int x, int y, int w, int h, uint32_t flags) {
    return SDL_CreateWindow(title, x, y, w, h, flags | SDL_WINDOW_ALLOW_HIGHDPI);
}

__attribute__((used)) static const struct {
    const void *replacement;
    const void *replacee;
} interposers[] __attribute__((section("__DATA,__interpose"))) = {
    {(const void *)urr_CreateWindow, (const void *)SDL_CreateWindow},
};
