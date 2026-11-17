#pragma once

/* Store only these row counts. Zero is the caller's sentinel for an absent or invalid preference. */
static inline int botw_handheld_scene_rows(long saved_rows, int is_ipad) {
    switch (saved_rows) {
    case 540: return 540;
    case 432: return 432;
    case 360: return 360;
    default: return is_ipad ? 540 : 432;
    }
}

/* BOTW 1.6.0 on iOS. Call once before creating the host thread, with the validated preference. */
void runtime_ios_set_boot_scene_rows(long saved_rows, int is_ipad);
/* An actual guest drawable's Metal presentation is the quality trial's success boundary. */
void runtime_ios_note_scene_presented(double presented_time, int interpolated);
