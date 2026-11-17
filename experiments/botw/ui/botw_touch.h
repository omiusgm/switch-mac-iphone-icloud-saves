/* Read-only iOS BOTW 1.6.0 touch HUD. Call snapshot and icon on the same serial worker queue. */
#pragma once
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
    BOTW_TOUCH_SWORD, BOTW_TOUCH_BOW, BOTW_TOUCH_SHIELD, BOTW_TOUCH_ARROWS,
    BOTW_TOUCH_EQUIPMENT_COUNT
};
enum { BOTW_TOUCH_RUNE_COUNT = 8, BOTW_TOUCH_ACTOR_CAP = 64 };

typedef struct {
    bool equipment_known, owned_runes_known;
    int selected_rune;    /* -1 while the game state is unavailable */
    uint8_t owned_runes;  /* Valid even when zero, if owned_runes_known */
    char equipped[BOTW_TOUCH_EQUIPMENT_COUNT][BOTW_TOUCH_ACTOR_CAP];
} BOTWTouchSnapshot;

typedef struct {
    unsigned width, height;
    uint8_t *rgba;         /* Straight-alpha RGBA8. Caller frees with free(). */
} BOTWTouchIcon;

typedef enum {
    BOTW_TOUCH_RUNTIME_UNAVAILABLE,
    BOTW_TOUCH_MODULE_SLOT,
    BOTW_TOUCH_MODULE_BUSY,
    BOTW_TOUCH_MEMORY_BUSY,
    BOTW_TOUCH_LOCK_ERROR,
    BOTW_TOUCH_DATA_RANGE,
    BOTW_TOUCH_DATA_UNMAPPED,
    BOTW_TOUCH_DATA_MOVED,
    BOTW_TOUCH_VM_COPY,
    BOTW_TOUCH_GDT_LAYOUT,
    BOTW_TOUCH_FLAG_TYPE,
    BOTW_TOUCH_FLAG_MISSING,
    BOTW_TOUCH_SELECTION_RANGE,
    BOTW_TOUCH_UNSTABLE,
    BOTW_TOUCH_REASON_COUNT
} BOTWTouchReason;

void botw_touch_snapshot(BOTWTouchSnapshot *out);
/* Diagnostic bits describe the rune reads only, excluding equipment. */
void botw_touch_snapshot_diagnostic(BOTWTouchSnapshot *out, uint32_t *reasons);

const char *botw_touch_rune_actor(unsigned rune);
bool botw_touch_icon(const char *actor, BOTWTouchIcon *out);

#ifdef __cplusplus
}
#endif
