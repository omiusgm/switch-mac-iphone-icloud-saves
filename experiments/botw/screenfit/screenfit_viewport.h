#pragma once
#include <math.h>

typedef struct { double x, y, w, h; } ScreenfitRect;

/* Fit the camera's logical shape, even when the intermediate canvas uses
   different dimensions. Round to the nearest pixel and centre the result. */
static inline ScreenfitRect screenfit_fit(double width, double height, double aspect) {
    const double h = fmin(height, width / aspect);
    const double w = round(h * aspect);
    const double rows = round(h);
    return (ScreenfitRect){ floor((width - w) / 2), floor((height - rows) / 2), w, rows };
}
