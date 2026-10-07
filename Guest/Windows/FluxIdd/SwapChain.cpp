#include "FluxIdd.h"
NTSTATUS FluxIddMonitorAssignSwapChain(IDDCX_MONITOR monitor, const IDARG_IN_SETSWAPCHAIN* args) {
    OutputDebugStringA("FluxIdd: FluxIddMonitorAssignSwapChain entered\n");
    auto* ctx = FluxGetMonitorContext(monitor);
    if (ctx) {
        ctx->swapChain = args->hSwapChain;
    }
    return STATUS_SUCCESS;
}
NTSTATUS FluxIddMonitorUnassignSwapChain(IDDCX_MONITOR monitor) {
    OutputDebugStringA("FluxIdd: FluxIddMonitorUnassignSwapChain entered\n");
    auto* ctx = FluxGetMonitorContext(monitor);
    if (ctx && ctx->swapChain) {
        WdfObjectDelete(ctx->swapChain);
        ctx->swapChain = nullptr;
    }
    return STATUS_SUCCESS;
}
