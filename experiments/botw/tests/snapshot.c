#include "botw_touch_internal.h"
#include <assert.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

enum {
    POUCH_INSTANCE = 0x2ca6d50, GDT_INSTANCE = 0x2cd1700,
    POUCH_LIST = 0x68, POUCH_ITEMS = 0x98, ITEM_STRIDE = 0x298, ITEM_NODE = 0x08,
    GUEST_BYTES = 1024 * 1024, PAGE = 4096
};
static const char digest[] = "c41ac2fa9be737f2e6b0ab641508e9a51995b03463ff6aa445ce04e5e8766a8e";
static const uint32_t sorted_hashes[] = {
    0x191bccf9, 0x3e4a4bd5, 0x5992b256, 0x7504085d,
    0x795e7bbc, 0x89ebcae4, 0xc9328299, 0xf7dd3e03
};

static uint8_t *guest, *module, *pouch, *manager, *trigger, *selected_flag;
static uint8_t pages[GUEST_BYTES / PAGE];
static unsigned copy_calls;
static uintptr_t mutate_on_copy;
static unsigned mutate_after;
static uint8_t *flag_bytes[8];

static void put32(void *address, uint32_t value) { memcpy(address, &value, sizeof value); }
static void put64(void *address, uintptr_t value) { memcpy(address, &value, sizeof value); }

/* The actual loader permission gate has its own module_permission.c probe. */
bool runtime_botw_touch_copy_main_pointer(uintptr_t main, unsigned offset, uintptr_t *out) {
    return botw_touch_copy_vm(main + offset, out, sizeof *out);
}

bool runtime_botw_touch_copy_data(uintptr_t address, void *out, size_t size) {
    copy_calls++;
    if (!botw_touch_range_contains(address, size, (uintptr_t)guest, GUEST_BYTES) ||
        !botw_touch_alias_pages_present(pages, sizeof pages, address - (uintptr_t)guest, size))
        return false;
    bool copied = botw_touch_copy_vm(address, out, size);
    if (copied && address == mutate_on_copy && mutate_after-- == 1)
        put32(selected_flag + 0x18, 5);
    return copied;
}

static uint8_t *item(unsigned index) { return pouch + POUCH_ITEMS + index * ITEM_STRIDE; }
static uintptr_t node(unsigned index) { return (uintptr_t)item(index) + ITEM_NODE; }

static void pouch_fixture(unsigned count) {
    uintptr_t head = (uintptr_t)pouch + POUCH_LIST;
    put64(pouch + POUCH_LIST, count ? node(count - 1) : head);
    put64(pouch + POUCH_LIST + 8, count ? node(0) : head);
    put32(pouch + POUCH_LIST + 0x10, count);
    put32(pouch + POUCH_LIST + 0x14, 8);
    for (unsigned i = 0; i < count; i++) {
        uint8_t *data = item(i);
        memset(data, 0, ITEM_STRIDE);
        put64(data + ITEM_NODE, i == 0 ? head : node(i - 1));
        put64(data + ITEM_NODE + 8, i + 1 == count ? head : node(i + 1));
        put32(data + 0x18, 7);
    }
    if (count < 4) return;
    const char *const names[] = {"Weapon_Sword_070", "Weapon_Bow_036", "NormalArrow", "Weapon_Shield_030"};
    for (unsigned i = 0; i < 4; i++) {
        put32(item(i) + 0x18, i);
        item(i)[0x24] = 1;
        strcpy((char *)item(i) + 0x3c, names[i]);
    }
}

static void rune_fixture(void) {
    uint8_t *bools = guest + 0x52000, *s32s = guest + 0x52100;
    selected_flag = guest + 0x52200;
    put64(manager + 0xc00, (uintptr_t)trigger);
    put32(trigger + 8, 8);
    put32(trigger + 12, 8);
    put64(trigger + 16, (uintptr_t)bools);
    put32(trigger + 24, 1);
    put32(trigger + 28, 1);
    put64(trigger + 32, (uintptr_t)s32s);
    put64(s32s, (uintptr_t)selected_flag);
    selected_flag[8] = 1;
    put32(selected_flag + 0x18, 2);
    put32(selected_flag + 0x1c, 0xa439d800);
    for (unsigned i = 0; i < 8; i++) {
        uint8_t *flag = guest + 0x53000 + i * 0x20;
        flag_bytes[i] = flag;
        put64(bools + i * 8, (uintptr_t)flag);
        put32(flag + 0xc, sorted_hashes[i]);
        flag[0xb] = 0x80 | (i == 0 || i == 4);
    }
}

static void init(void) {
    const int permission = PROT_READ | PROT_WRITE;
    module = mmap(NULL, GDT_INSTANCE + 8, permission, MAP_PRIVATE | MAP_ANON, -1, 0);
    guest = mmap(NULL, GUEST_BYTES, permission, MAP_PRIVATE | MAP_ANON, -1, 0);
    assert(module != MAP_FAILED && guest != MAP_FAILED);
    memset(pages, 1, sizeof pages);
    pouch = guest + 0x1000;
    manager = guest + 0x50000;
    trigger = guest + 0x51000;
    put64(module + POUCH_INSTANCE, (uintptr_t)pouch);
    put64(module + GDT_INSTANCE, (uintptr_t)manager);
    pouch_fixture(4);
    rune_fixture();
}

static _Atomic bool stop_race;
static void *move_vm_page(void *unused) {
    (void)unused;
    size_t page_size = (size_t)getpagesize();
    uintptr_t addr = (uintptr_t)trigger & ~(page_size - 1);
    while (!atomic_load_explicit(&stop_race, memory_order_relaxed)) {
        assert(mprotect((void *)addr, page_size, PROT_NONE) == 0);
        assert(mprotect((void *)addr, page_size, PROT_READ | PROT_WRITE) == 0);
    }
    return NULL;
}

static uint64_t monotonic_ns(void) {
    struct timespec time;
    clock_gettime(CLOCK_MONOTONIC, &time);
    return (uint64_t)time.tv_sec * UINT64_C(1000000000) + time.tv_nsec;
}

static void benchmark(unsigned inventory, unsigned polls) {
    BOTWTouchSnapshot out;
    pouch_fixture(inventory);
    copy_calls = 0;
    uint64_t start = monotonic_ns();
    for (unsigned i = 0; i < polls; i++) {
        botw_touch_snapshot(&out);
        assert(out.equipment_known && out.selected_rune == 2 && out.owned_runes_known);
    }
    double ms = (monotonic_ns() - start) / 1e6 / polls;
    printf("inventory=%u mean=%.3f ms/poll checked-data-copies=%u/poll\n",
           inventory, ms, copy_calls / polls);
}

int main(void) {
    BOTWTouchSnapshot out;
    botw_touch_snapshot(&out);
    assert(!out.equipment_known && out.selected_rune == -1 && !copy_calls);
    init();
    botw_touch_set_main((uintptr_t)module, "wrong version");
    botw_touch_snapshot(&out);
    assert(!out.equipment_known && out.selected_rune == -1 && !copy_calls);
    botw_touch_set_main(UINTPTR_MAX - 7, digest);
    botw_touch_snapshot(&out);
    assert(!out.equipment_known && out.selected_rune == -1 && !copy_calls);
    botw_touch_set_main((uintptr_t)module, digest);
    botw_touch_snapshot(&out);
    assert(out.equipment_known && out.selected_rune == 2 && out.owned_runes_known && out.owned_runes == 7);
    assert(!strcmp(out.equipped[BOTW_TOUCH_SWORD], "Weapon_Sword_070"));
    assert(!strcmp(out.equipped[BOTW_TOUCH_BOW], "Weapon_Bow_036"));
    assert(!strcmp(out.equipped[BOTW_TOUCH_SHIELD], "Weapon_Shield_030"));
    assert(!strcmp(out.equipped[BOTW_TOUCH_ARROWS], "NormalArrow"));

    /* Flag category bits remain set when the owned flags are all false. */
    for (unsigned i = 0; i < 8; i++) flag_bytes[i][0xb] = 0x80;
    botw_touch_snapshot(&out);
    assert(out.owned_runes_known && !out.owned_runes);
    flag_bytes[0][0xb] = 0x81;
    flag_bytes[4][0xb] = 0x81;

    /* Two complete readbacks see different values. */
    mutate_on_copy = (uintptr_t)selected_flag;
    mutate_after = 1;
    botw_touch_snapshot(&out);
    assert(out.selected_rune == -1 && out.owned_runes_known);
    mutate_on_copy = 0;
    put32(selected_flag + 0x18, 9);
    botw_touch_snapshot(&out);
    assert(out.selected_rune == -1 && out.owned_runes_known);
    put32(selected_flag + 0x18, 2);

    uint8_t scratch[16];
    assert(!botw_touch_copy_vm(UINTPTR_MAX - 7, scratch, sizeof scratch));
    assert(!botw_touch_copy_vm((uintptr_t)module + POUCH_INSTANCE, scratch, 129));
    assert(!botw_touch_range_contains(1, 1, 0, UINT64_MAX));
    assert(!botw_touch_alias_pages_present(pages, sizeof pages, SIZE_MAX - 1, sizeof scratch));
    pages[0x53] = 0;
    assert(botw_touch_copy_vm((uintptr_t)guest + 0x53000, scratch, sizeof scratch));
    assert(!botw_touch_alias_pages_present(pages, sizeof pages, 0x52ff8, sizeof scratch));
    botw_touch_snapshot(&out);
    assert(out.selected_rune == 2 && !out.owned_runes_known);
    pages[0x53] = 1;

    unsigned host_page_size = (unsigned)getpagesize();
    void *unmapped = mmap(NULL, host_page_size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    assert(unmapped != MAP_FAILED);
    assert(mprotect(unmapped, host_page_size, PROT_NONE) == 0);
    assert(!botw_touch_copy_vm((uintptr_t)unmapped, scratch, sizeof scratch));
    assert(munmap(unmapped, host_page_size) == 0);
    assert(!botw_touch_copy_vm((uintptr_t)unmapped, scratch, sizeof scratch));

    put64(item(1) + 0x10, node(1));
    botw_touch_snapshot(&out);
    assert(!out.equipment_known && !out.equipped[0][0]);
    pouch_fixture(4);
    item(0)[0x3c] = '.';
    botw_touch_snapshot(&out);
    assert(!out.equipment_known);
    pouch_fixture(4);
    put32(pouch + POUCH_LIST + 0x10, 421);
    botw_touch_snapshot(&out);
    assert(!out.equipment_known);
    pouch_fixture(0);
    botw_touch_snapshot(&out);
    assert(out.equipment_known && !out.equipped[0][0]);
    put32(trigger + 28, 400001);
    botw_touch_snapshot(&out);
    assert(out.selected_rune == -1 && !out.owned_runes_known);
    rune_fixture();

    pthread_t racer;
    assert(pthread_create(&racer, NULL, move_vm_page, NULL) == 0);
    for (unsigned i = 0; i < 100; i++) {
        botw_touch_snapshot(&out);
        assert(out.selected_rune == -1 || out.selected_rune == 2);
        assert(!out.owned_runes_known || out.owned_runes == 7);
    }
    atomic_store_explicit(&stop_race, true, memory_order_relaxed);
    assert(pthread_join(racer, NULL) == 0);
    benchmark(4, 500);
    benchmark(100, 500);
    benchmark(420, 500);
    assert(munmap(module, GDT_INSTANCE + 8) == 0 && munmap(guest, GUEST_BYTES) == 0);
    puts("guest snapshot bounds, invalid states and Mach unmap/race probes passed");
}
