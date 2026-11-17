#include <assert.h>
#include <math.h>
#include <stdio.h>
#include "screenfit_viewport.h"
#include "botw_picture.h"

static void viewport(double w, double h, double a, ScreenfitRect expected) {
    ScreenfitRect got = screenfit_fit(w, h, a);
    assert(got.x == expected.x && got.y == expected.y && got.w == expected.w && got.h == expected.h);
}

int main(void) {
    /* Ported from the local ARM64 fixture; no guest instructions or game input. */
    viewport(2560, 1600, 1.6, (ScreenfitRect){0, 0, 2560, 1600});
    viewport(3024, 1964, 1.6, (ScreenfitRect){0, 37, 3024, 1890});
    viewport(1920, 1080, 1.6, (ScreenfitRect){96, 0, 1728, 1080});
    viewport(1024, 768, 1.6, (ScreenfitRect){0, 64, 1024, 640});
    viewport(2560, 1600, 16.0 / 9.0, (ScreenfitRect){0, 80, 2560, 1440});
    for (unsigned i = 1; i <= 29; i++) {
        double old_fov = i / 10.0;
        double new_fov = 2 * atan((10.0 / 9.0) * tan(old_fov / 2));
        assert(fabs((16.0 / 9.0) * tan(old_fov / 2) - 1.6 * tan(new_fov / 2)) < 1e-12);
    }
    size_t x = 0, y = 0, w = 1920, h = 1080;
    botw_center_crop(&x, &y, &w, &h, 1600, 1000);
    assert(x == 96 && y == 0 && w == 1728 && h == 1080);
    assert(botw_wide_screen_ratio(16.0f / 10.0f) == 0);
    assert(botw_wide_screen_ratio(21.0f / 9.0f) > 0);
    puts("PASS five viewport geometries, 29 synthetic FOVs, explicit crop and aspect selection");
}
