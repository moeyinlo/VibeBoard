// SwiftPM requires at least one source file in a C target; the header carries the ABI.
#include "vibeboard_core.h"

int vibeboard_core_abi_version(void) {
    return 1;
}
