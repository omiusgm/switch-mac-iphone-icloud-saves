#pragma once
#include <stddef.h>

typedef enum {
    BOTWPictureAutomatic,
    BOTWPictureLetterbox,
    BOTWPictureFill,
} BOTWPictureFormat;

/* A wider screen can use the game's wide camera. Narrower displays use the original camera. */
static inline float botw_wide_screen_ratio(float ratio) {
    return ratio > (16.0f / 9.0f) * 1.01f && ratio <= 8.0f ? ratio : 0;
}

/* Match the drawable without changing the scene's proportions. Crop only when explicitly requested. */
static inline void botw_center_crop(size_t *x, size_t *y, size_t *w, size_t *h,
                                    size_t out_w, size_t out_h) {
    if (!out_w || !out_h || !*w || !*h) return;
    if (*w * out_h > *h * out_w) {
        size_t new_w = *h * out_w / out_h;
        if (new_w) { *x += (*w - new_w) / 2; *w = new_w; }
    } else {
        size_t new_h = *w * out_h / out_w;
        if (new_h) { *y += (*h - new_h) / 2; *h = new_h; }
    }
}

int runtime_ios_picture_format(void);
void runtime_ios_set_picture_format(BOTWPictureFormat format);
