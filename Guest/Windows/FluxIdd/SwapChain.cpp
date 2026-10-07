#include "FluxIdd.h"
NTSTATUS FluxIddMonitorAssignSwapChain(IDDCX_MONITOR, const IDARG_IN_SETSWAPCHAIN* args) {
    OutputDebugStringA("FluxIdd: FluxIddMonitorAssignSwapChain entered\n");
    // Future implementation: IddCx frame -> Flux transport -> shared surface -> Metal.
    // This build-only skeleton deliberately declines a scanout it cannot consume.
    WdfObjectDelete(args->hSwapChain); return STATUS_SUCCESS;
}
NTSTATUS FluxIddMonitorUnassignSwapChain(IDDCX_MONITOR) {
    OutputDebugStringA("FluxIdd: FluxIddMonitorUnassignSwapChain entered\n");
    return STATUS_SUCCESS;
}
