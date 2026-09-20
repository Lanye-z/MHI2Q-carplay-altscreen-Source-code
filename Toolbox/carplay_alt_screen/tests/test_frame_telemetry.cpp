#include "../src/private111_direct_shm.h"
#include <stddef.h>
#include <stdio.h>

typedef char check_v2[(P111_FRAME_SHM_VERSION == 2u) ? 1 : -1];
typedef char check_slot_size[(sizeof(p111_frame_timing_t) == 20u) ? 1 : -1];
typedef char check_data_offset[(offsetof(p111_frame_shm_t, data) == 124u) ? 1 : -1];

int main() {
    if (p111_timing_delta_us32(1000u, 500u) != 500u) return 1;
    if (p111_timing_delta_us32(0x00000100u, 0xffffff00u) != 512u) return 2;
    if (p111_timing_delta_us32(0u, 500u) != 0u) return 3;
    if (p111_timing_delta_us32(1000u, 0u) != 0u) return 4;
    if (p111_timing_delta_us32(1000u, 2000u) != 0u) return 5;
    if (p111_timing_delta_us32(6000001u, 1u) != 0u) return 6;

    p111_frame_timing_t slots[P111_FRAME_SLOTS] = {};
    slots[0].h264_seq = 11u;
    slots[1].h264_seq = 12u;
    if (slots[0].h264_seq != 11u || slots[1].h264_seq != 12u ||
        slots[2].h264_seq != 0u) return 7;
    puts("FRAME_TELEMETRY_HOST_TEST=PASS");
    return 0;
}
