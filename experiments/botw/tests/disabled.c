#include "botw_touch.h"
#include <assert.h>
#include <stdio.h>

int main(void) {
    BOTWTouchSnapshot state;
    BOTWTouchIcon icon;
    botw_touch_snapshot(&state);
    assert(state.selected_rune == -1 && !state.owned_runes_known && !state.equipment_known);
    assert(!botw_touch_icon("Weapon_Sword_070", &icon));
    assert(!icon.rgba && !icon.width && !icon.height);
    puts("disabled-platform HUD returns unknown without runtime dependencies");
}
