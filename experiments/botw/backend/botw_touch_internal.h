#pragma once
#include "botw_touch.h"
#include <stddef.h>
#include <TargetConditionals.h>

#if defined(GAME_BOTW160) && TARGET_OS_IOS
#define BOTW_TOUCH_ENABLED 1
#else
#define BOTW_TOUCH_ENABLED 0
#endif
#define BOTW_TOUCH_MAX_COPY 128
#define BOTW_TOUCH_MAX_STOCK_ITEM (128u * 1024u)

static inline bool botw_touch_range_contains(uintptr_t address, size_t size,
                                             uintptr_t base, uint64_t length) {
    return base && size && size <= length && address >= base && address - base <= length - size;
}

/* The caller holds the guest mapping lock across this check and the VM copy. */
static inline bool botw_touch_alias_pages_present(const uint8_t *pages, size_t page_count,
                                                  size_t offset, size_t size) {
    if (!size || offset > SIZE_MAX - (size - 1)) return false;
    size_t first = offset / 4096, last = (offset + size - 1) / 4096;
    if (last >= page_count) return false;
    for (size_t page = first; page <= last; page++)
        if (!pages[page]) return false;
    return true;
}

/* The parser reads only into host-owned buffers. Returns false for any unreadable byte. */
bool botw_touch_read_failed(BOTWTouchReason reason);
bool botw_touch_copy_vm(uintptr_t address, void *out, size_t size);
bool runtime_botw_touch_copy_main_pointer(uintptr_t main, unsigned offset, uintptr_t *out);
bool runtime_botw_touch_copy_data(uintptr_t address, void *out, size_t size);
void botw_touch_set_main(uintptr_t base, const char *rewrite_digest);
bool botw_touch_valid_actor(const char *actor);
size_t runtime_romfs_read_stock_item(const char *name, uint8_t *out, size_t capacity);
bool botw_touch_decode_icon(const uint8_t *raw, size_t size, BOTWTouchIcon *out);
