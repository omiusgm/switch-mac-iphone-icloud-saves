#include "botw_touch_internal.h"
#include "botw_touch_license.h"
#if BOTW_TOUCH_ENABLED || defined(BOTW_TOUCH_TEST)
#include <pthread.h>
#include <stdatomic.h>
#include <string.h>
#include <mach/mach.h>
#include "mach_vm_compat.h"

/* The NSO build ID 8e9978d50bdd20b4c8395a106c27ffde is represented in this loader by
   the verified runtime-table digest of the local rewrite. Offsets are relative to
   the main module; its actual iOS base is chosen by Darwin. */
#define BOTW160_MAIN_DIGEST "c41ac2fa9be737f2e6b0ab641508e9a51995b03463ff6aa445ce04e5e8766a8e"
#define POUCH_INSTANCE 0x2ca6d50u
#define GDT_INSTANCE 0x2cd1700u

static _Atomic uintptr_t game_main;
static _Thread_local uint32_t *rune_reasons;

bool botw_touch_read_failed(BOTWTouchReason reason) {
    if (rune_reasons) *rune_reasons |= 1u << reason;
    return false;
}

void botw_touch_set_main(uintptr_t base, const char *rewrite_digest) {
    bool verified = rewrite_digest && !strcmp(rewrite_digest, BOTW160_MAIN_DIGEST) &&
                    base && !(base & 7) && base <= UINTPTR_MAX - GDT_INSTANCE - sizeof(uint64_t);
    atomic_store_explicit(&game_main, verified ? base : 0, memory_order_release);
}

bool botw_touch_copy_vm(uintptr_t address, void *out, size_t size) {
    if (!address || !out || !size || size > BOTW_TOUCH_MAX_COPY || address > UINTPTR_MAX - size)
        return false;
    mach_vm_size_t got = 0;
    return (mach_vm_read_overwrite(mach_task_self(), address, size, (uintptr_t)out, &got) ==
            KERN_SUCCESS && got == size) || botw_touch_read_failed(BOTW_TOUCH_VM_COPY);
}

/* PauseMenuDataMgr and PouchItem layouts from the upstream 1.6.0 pouch reader. */
enum {
    POUCH_LIST = 0x68, POUCH_ITEMS = 0x98, ITEM_STRIDE = 0x298, POUCH_MAX = 420,
    ITEM_NODE = 0x8, ITEM_TYPE = 0x18, ITEM_EQUIPPED = 0x24, ITEM_NAME = 0x3c
};

typedef struct { uint64_t prev, next; int32_t count, node_offset; } PouchList;
typedef struct { uintptr_t instance; PouchList list; char equipped[4][64]; } EquipmentSample;
_Static_assert(sizeof(PouchList) == 0x18 && ITEM_NAME + BOTW_TOUCH_ACTOR_CAP <= BOTW_TOUCH_MAX_COPY,
               "pouch layout");

static uint32_t read32(const uint8_t *bytes) {
    uint32_t value;
    memcpy(&value, bytes, sizeof value);
    return value;
}

static uint64_t read64(const uint8_t *bytes) {
    uint64_t value;
    memcpy(&value, bytes, sizeof value);
    return value;
}

static bool guest_data(uintptr_t address, void *out, size_t size) {
    if (address & 7) return botw_touch_read_failed(BOTW_TOUCH_GDT_LAYOUT);
    return runtime_botw_touch_copy_data(address, out, size);
}

static bool sample_equipment(uintptr_t main, EquipmentSample *sample) {
    if (!runtime_botw_touch_copy_main_pointer(main, POUCH_INSTANCE, &sample->instance) || !sample->instance ||
        sample->instance > UINTPTR_MAX - POUCH_ITEMS - POUCH_MAX * ITEM_STRIDE) return false;

    uintptr_t head = sample->instance + POUCH_LIST;
    uintptr_t first_item = sample->instance + POUCH_ITEMS;
    PouchList *list = &sample->list;
    if (!guest_data(head, list, sizeof *list) || list->node_offset != ITEM_NODE ||
        list->count < 0 || list->count > POUCH_MAX) return false;

    uintptr_t previous = head, node = list->next;
    for (int index = 0; index < list->count; index++) {
        if (node < first_item + ITEM_NODE) return false;
        uintptr_t item = node - ITEM_NODE, offset = item - first_item;
        if (offset >= POUCH_MAX * ITEM_STRIDE || offset % ITEM_STRIDE) return false;

        uint8_t data[ITEM_NAME + BOTW_TOUCH_ACTOR_CAP];
        if (!guest_data(item, data, sizeof data) || read64(data + ITEM_NODE) != previous)
            return false;
        unsigned type = read32(data + ITEM_TYPE);
        if (type <= 3) {
            static const unsigned slot_for_type[] = {
                BOTW_TOUCH_SWORD, BOTW_TOUCH_BOW, BOTW_TOUCH_ARROWS, BOTW_TOUCH_SHIELD
            };
            unsigned slot = slot_for_type[type];
            if (data[ITEM_EQUIPPED] > 1) return false;
            if (data[ITEM_EQUIPPED]) {
                const char *actor = (const char *)data + ITEM_NAME;
                if (sample->equipped[slot][0] || !botw_touch_valid_actor(actor)) return false;
                memcpy(sample->equipped[slot], actor, strlen(actor) + 1);
            }
        }
        previous = node;
        node = read64(data + ITEM_NODE + 8);
    }

    PouchList end;
    uintptr_t current;
    return node == head && previous == list->prev &&
           guest_data(head, &end, sizeof end) && !memcmp(&end, list, sizeof end) &&
           runtime_botw_touch_copy_main_pointer(main, POUCH_INSTANCE, &current) &&
           current == sample->instance;
}

static bool equipment_matches(const EquipmentSample *first, const EquipmentSample *second) {
    return first->instance == second->instance &&
           !memcmp(&first->list, &second->list, sizeof first->list) &&
           !memcmp(first->equipped, second->equipped, sizeof first->equipped);
}

/* The live TriggerParam is Manager::mFlagBuffer. In the 1.6.0 constructor,
   main+0x183f754 wires the +0xc00 field into both TriggerParamRefs. */
enum {
    GDT_LIVE = 0xc00, GDT_BOOL_ARRAY = 0x08, GDT_S32_ARRAY = 0x18,
    GDT_FLAG_TYPE = 0x08, GDT_BOOL_VALUE = 0x0b, GDT_BOOL_HASH = 0x0c,
    GDT_S32_VALUE = 0x18, GDT_S32_HASH = 0x1c, GDT_FLAGS_MAX = 400000
};

static const uint32_t rune_selected_hash = 0xa439d800u; /* PlayerEquipItemType in 1.6.0 GameData */
static const uint32_t rune_owned_hash[BOTW_TOUCH_RUNE_COUNT] = {
    0x191bccf9, 0x3e4a4bd5, 0x795e7bbc, 0x7504085d,
    0x5992b256, 0xf7dd3e03, 0xc9328299, 0x89ebcae4
};

typedef struct { int32_t count, capacity; uintptr_t pointers; } FlagArray;
typedef struct {
    uintptr_t instance, live;
    FlagArray bools, s32s;
    int selected;
    uint8_t owned;
    bool owned_known;
} RuneSample;

_Static_assert(sizeof(FlagArray) == 16, "gdt pointer array layout");

static bool array_valid(FlagArray array) {
    return array.count > 0 && array.count <= array.capacity && array.capacity <= GDT_FLAGS_MAX &&
           array.pointers && !(array.pointers & 7) &&
           (size_t)array.count * sizeof(uintptr_t) <= UINTPTR_MAX - array.pointers;
}

static bool flag_at(FlagArray array, unsigned index, bool s32, uint32_t *hash, uint32_t *value) {
    uintptr_t flag;
    uint8_t bytes[GDT_S32_HASH + sizeof(uint32_t)];
    size_t size = s32 ? sizeof bytes : GDT_BOOL_HASH + sizeof(uint32_t);
    if (index >= (unsigned)array.count ||
        !guest_data(array.pointers + index * sizeof flag, &flag, sizeof flag) ||
        !guest_data(flag, bytes, size)) return false;
    if (bytes[GDT_FLAG_TYPE] != (s32 ? 1 : 0)) return botw_touch_read_failed(BOTW_TOUCH_FLAG_TYPE);
    *hash = read32(bytes + (s32 ? GDT_S32_HASH : GDT_BOOL_HASH));
    /* The other bits in a FlagBool encode its category. */
    *value = s32 ? read32(bytes + GDT_S32_VALUE) : bytes[GDT_BOOL_VALUE] & 1u;
    return true;
}

/* Cache indices only. Re-resolve and verify the flag's type/hash on every read.
   TriggerParam sorts each PtrArray by unsigned CRC32 (same search as the game). */
static bool find_flag(FlagArray array, bool s32, uint32_t wanted, unsigned *cached, uint32_t *value) {
    if (!array_valid(array)) return botw_touch_read_failed(BOTW_TOUCH_GDT_LAYOUT);
    uint32_t hash;
    if (flag_at(array, *cached, s32, &hash, value) && hash == wanted) return true;
    unsigned lo = 0, hi = (unsigned)array.count;
    while (lo < hi) {
        unsigned mid = lo + (hi - lo) / 2;
        if (!flag_at(array, mid, s32, &hash, value)) return false;
        if (hash == wanted) {
            *cached = mid;
            return true;
        }
        if (hash < wanted) lo = mid + 1;
        else hi = mid;
    }
    return botw_touch_read_failed(BOTW_TOUCH_FLAG_MISSING);
}

static bool sample_runes(uintptr_t main, RuneSample *sample) {
    static unsigned selected_index, owned_indices[BOTW_TOUCH_RUNE_COUNT];
    FlagArray arrays[2], end[2];
    sample->selected = -1;
    if (!runtime_botw_touch_copy_main_pointer(main, GDT_INSTANCE, &sample->instance)) return false;
    if (!sample->instance) return botw_touch_read_failed(BOTW_TOUCH_RUNTIME_UNAVAILABLE);
    if (sample->instance > UINTPTR_MAX - GDT_LIVE) return botw_touch_read_failed(BOTW_TOUCH_GDT_LAYOUT);
    if (!guest_data(sample->instance + GDT_LIVE, &sample->live, sizeof sample->live)) return false;
    if (!sample->live) return botw_touch_read_failed(BOTW_TOUCH_RUNTIME_UNAVAILABLE);
    if (sample->live > UINTPTR_MAX - GDT_S32_ARRAY) return botw_touch_read_failed(BOTW_TOUCH_GDT_LAYOUT);
    if (!guest_data(sample->live + GDT_BOOL_ARRAY, arrays, sizeof arrays)) return false;
    sample->bools = arrays[0];
    sample->s32s = arrays[1];

    uint32_t value;
    if (!find_flag(sample->s32s, true, rune_selected_hash, &selected_index, &value)) return false;
    if (value < BOTW_TOUCH_RUNE_COUNT) sample->selected = (int)value;
    else botw_touch_read_failed(BOTW_TOUCH_SELECTION_RANGE);

    sample->owned_known = true;
    for (unsigned rune = 0; rune < BOTW_TOUCH_RUNE_COUNT; rune++) {
        if (!find_flag(sample->bools, false, rune_owned_hash[rune], &owned_indices[rune], &value)) {
            sample->owned_known = false;
            sample->owned = 0;
            break;
        }
        if (value) sample->owned |= 1u << rune;
    }
    if (sample->owned & 1u) sample->owned |= 2u; /* both bomb variants unlock together */

    uintptr_t current_live, current_instance;
    if (!guest_data(sample->live + GDT_BOOL_ARRAY, end, sizeof end)) return false;
    if (memcmp(arrays, end, sizeof arrays)) return botw_touch_read_failed(BOTW_TOUCH_UNSTABLE);
    if (!guest_data(sample->instance + GDT_LIVE, &current_live, sizeof current_live)) return false;
    if (current_live != sample->live) return botw_touch_read_failed(BOTW_TOUCH_UNSTABLE);
    if (!runtime_botw_touch_copy_main_pointer(main, GDT_INSTANCE, &current_instance)) return false;
    return current_instance == sample->instance || botw_touch_read_failed(BOTW_TOUCH_UNSTABLE);
}

static bool rune_buffers_match(const RuneSample *first, const RuneSample *second) {
    return first->instance == second->instance && first->live == second->live &&
           !memcmp(&first->bools, &second->bools, sizeof first->bools) &&
           !memcmp(&first->s32s, &second->s32s, sizeof first->s32s);
}
#endif

void botw_touch_snapshot_diagnostic(BOTWTouchSnapshot *out, uint32_t *reasons) {
    if (reasons) *reasons = 0;
    if (!out) return;
    *out = (BOTWTouchSnapshot){ .selected_rune = -1 };
#if BOTW_TOUCH_ENABLED || defined(BOTW_TOUCH_TEST)
#if !defined(BOTW_TOUCH_TEST)
    if (pthread_main_np()) {
        if (reasons) *reasons = 1u << BOTW_TOUCH_RUNTIME_UNAVAILABLE;
        return;
    }
#endif
    uintptr_t main = atomic_load_explicit(&game_main, memory_order_acquire);
    if (!main) {
        if (reasons) *reasons = 1u << BOTW_TOUCH_RUNTIME_UNAVAILABLE;
        return;
    }

    EquipmentSample equipment[2] = {0};
    if (sample_equipment(main, &equipment[0]) && sample_equipment(main, &equipment[1]) &&
        equipment_matches(&equipment[0], &equipment[1])) {
        out->equipment_known = true;
        memcpy(out->equipped, equipment[0].equipped, sizeof out->equipped);
    }

    uint32_t *previous = rune_reasons;
    rune_reasons = reasons;
    RuneSample runes[2] = {0};
    if (sample_runes(main, &runes[0]) && sample_runes(main, &runes[1])) {
        if (!rune_buffers_match(&runes[0], &runes[1])) {
            botw_touch_read_failed(BOTW_TOUCH_UNSTABLE);
        } else {
            if (runes[0].selected == runes[1].selected) out->selected_rune = runes[0].selected;
            else botw_touch_read_failed(BOTW_TOUCH_UNSTABLE);
            if (runes[0].owned_known && runes[1].owned_known) {
                if (runes[0].owned == runes[1].owned) {
                    out->owned_runes_known = true;
                    out->owned_runes = runes[0].owned;
                } else botw_touch_read_failed(BOTW_TOUCH_UNSTABLE);
            }
        }
    }
    rune_reasons = previous;
#endif
}

void botw_touch_snapshot(BOTWTouchSnapshot *out) {
    botw_touch_snapshot_diagnostic(out, NULL);
}
