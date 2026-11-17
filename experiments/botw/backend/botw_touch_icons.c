#include "botw_touch_internal.h"
#include "botw_touch_license.h"
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

const char *botw_touch_rune_actor(unsigned rune) {
    static const char *const actors[BOTW_TOUCH_RUNE_COUNT] = {
        "Obj_RemoteBombBall", "Obj_RemoteBombCube", "Obj_Magnetglove", "Obj_StopTimer",
        "Obj_IceMaker", "Obj_Camera", "Obj_Motorcycle", "Obj_AmiiboItem"
    };
    return rune < BOTW_TOUCH_RUNE_COUNT ? actors[rune] : NULL;
}

bool botw_touch_valid_actor(const char *actor) {
    if (!actor || !*actor) return false;
    for (unsigned i = 0; i < BOTW_TOUCH_ACTOR_CAP; i++) {
        unsigned char c = actor[i];
        if (!c) return true;
        if (!((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
              (c >= '0' && c <= '9') || c == '_')) return false;
    }
    return false;
}

/* StockItem files observed in the base game are below 56 KiB compressed.
   The expanded files are FRES containers with one small block-linear RGBA8 texture. */
#define MAX_EXPANDED (512u * 1024u)
#define MAX_ICON_SIDE 256u
static uint8_t *yaz0(const uint8_t *input, size_t length, size_t *decoded_size) {
    if (length < 16 || length > BOTW_TOUCH_MAX_STOCK_ITEM || memcmp(input, "Yaz0", 4))
        return NULL;
    size_t size = (size_t)input[4] << 24 | (size_t)input[5] << 16 |
                  (size_t)input[6] << 8 | input[7];
    if (!size || size > MAX_EXPANDED) return NULL;
    uint8_t *output = malloc(size);
    if (!output) return NULL;
    size_t read_at = 16, write_at = 0;
    while (write_at < size) {
        if (read_at == length) goto invalid;
        uint8_t code = input[read_at++];
        for (unsigned bit = 0; bit < 8 && write_at < size; bit++, code <<= 1) {
            if (code & 0x80) {
                if (read_at == length) goto invalid;
                output[write_at++] = input[read_at++];
                continue;
            }
            if (length - read_at < 2) goto invalid;
            unsigned first = input[read_at++], second = input[read_at++];
            size_t distance = ((first & 0xf) << 8 | second) + 1;
            size_t count = first >> 4;
            if (count) count += 2;
            else {
                if (read_at == length) goto invalid;
                count = (size_t)input[read_at++] + 0x12;
            }
            if (distance > write_at || count > size - write_at) goto invalid;
            while (count--) {
                output[write_at] = output[write_at - distance];
                write_at++;
            }
        }
    }
    *decoded_size = size;
    return output;
invalid:
    free(output);
    return NULL;
}

static uint32_t le32(const uint8_t *p) {
    return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}

static uint64_t le64(const uint8_t *p) {
    return le32(p) | (uint64_t)le32(p + 4) << 32;
}

static bool contains(size_t size, uint64_t offset, size_t length) {
    return offset <= size && length <= size - offset;
}

static bool bntx_rgba(const uint8_t *file, size_t size, BOTWTouchIcon *out) {
    while (size >= 0x30 && memcmp(file, "BNTX\0\0\0\0", 8)) {
        ++file;
        --size;
    }
    if (size < 0x30 || file[0xc] != 0xff || file[0xd] != 0xfe) return false;
    uint64_t entries = le64(file + 0x28);
    if (!contains(size, entries, 8)) return false;
    uint64_t texture = le64(file + entries);
    if (!contains(size, texture, 0x78) || memcmp(file + texture, "BRTI", 4)) return false;
    const uint8_t *info = file + texture;
    unsigned format = le32(info + 0x1c), block_height = le32(info + 0x34);
    unsigned width = le32(info + 0x24), height = le32(info + 0x28);
    if ((format >> 8) != 0x0b || !width || !height ||
        width > MAX_ICON_SIDE || height > MAX_ICON_SIDE || block_height > 5) return false;

    uint64_t mip_table = le64(info + 0x70);
    if (!contains(size, mip_table, 8)) return false;
    uint64_t data = le64(file + mip_table);
    unsigned pitch = width * 4, gobs_per_row = (pitch + 63) / 64;
    if (!contains(size, data, (size_t)pitch * height)) return false;
    uint8_t *pixels = malloc((size_t)pitch * height);
    if (!pixels) return false;

    /* Tegra GOB layout, x in bytes. This matches the upstream decoder's transform. */
    for (unsigned y = 0; y < height; y++) {
        unsigned gy = y >> 3;
        for (unsigned x = 0; x < pitch; x++) {
            size_t address = ((gy >> block_height) * gobs_per_row + (x >> 6)) * (512u << block_height) +
                (gy & ((1u << block_height) - 1)) * 512u + ((x & 63) >> 5) * 256u +
                ((y & 7) >> 1) * 64u + (((x & 63) >> 4) & 1) * 32u + (y & 1) * 16u + (x & 15);
            if (address >= size - data) {
                free(pixels);
                return false;
            }
            pixels[(size_t)y * pitch + x] = file[data + address];
        }
    }
    *out = (BOTWTouchIcon){ .width = width, .height = height, .rgba = pixels };
    return true;
}

bool botw_touch_decode_icon(const uint8_t *raw, size_t size, BOTWTouchIcon *out) {
    if (!out) return false;
    *out = (BOTWTouchIcon){0};
    if (!raw) return false;
    size_t decoded_size = 0;
    uint8_t *decoded = yaz0(raw, size, &decoded_size);
    if (!decoded) return false;
    bool result = bntx_rgba(decoded, decoded_size, out);
    free(decoded);
    return result;
}

bool botw_touch_icon(const char *actor, BOTWTouchIcon *out) {
    if (!out) return false;
    *out = (BOTWTouchIcon){0};
#if BOTW_TOUCH_ENABLED
    if (pthread_main_np() || !botw_touch_valid_actor(actor)) return false;
    char name[sizeof("UI/StockItem/.sbitemico") + BOTW_TOUCH_ACTOR_CAP - 1];
    snprintf(name, sizeof name, "UI/StockItem/%s.sbitemico", actor);
    uint8_t *raw = malloc(BOTW_TOUCH_MAX_STOCK_ITEM);
    if (!raw) return false;
    size_t size = runtime_romfs_read_stock_item(name, raw, BOTW_TOUCH_MAX_STOCK_ITEM);
    bool decoded = botw_touch_decode_icon(raw, size, out);
    free(raw);
    return decoded;
#else
    (void)actor;
    return false;
#endif
}
