#include "FluxIdd.h"
extern "C" BOOL WINAPI DllMain(HINSTANCE, DWORD, LPVOID) { return TRUE; }
extern "C" NTSTATUS DriverEntry(PDRIVER_OBJECT driverObject, PUNICODE_STRING registryPath) {
    OutputDebugStringA("FluxIdd: DriverEntry entered\n");
    WDF_DRIVER_CONFIG config; WDF_DRIVER_CONFIG_INIT(&config, FluxIddDeviceAdd);
    WDF_OBJECT_ATTRIBUTES attributes; WDF_OBJECT_ATTRIBUTES_INIT(&attributes);
    NTSTATUS status = WdfDriverCreate(driverObject, registryPath, &attributes, &config, WDF_NO_HANDLE);
    if (!NT_SUCCESS(status)) {
        OutputDebugStringA("FluxIdd: WdfDriverCreate failed\n");
    } else {
        OutputDebugStringA("FluxIdd: WdfDriverCreate success\n");
    }
    return status;
}
NTSTATUS FluxIddDeviceAdd(WDFDRIVER, PWDFDEVICE_INIT deviceInit) {
    OutputDebugStringA("FluxIdd: FluxIddDeviceAdd entered\n");
    WDF_PNPPOWER_EVENT_CALLBACKS power; WDF_PNPPOWER_EVENT_CALLBACKS_INIT(&power);
    power.EvtDeviceD0Entry = FluxIddDeviceD0Entry; WdfDeviceInitSetPnpPowerEventCallbacks(deviceInit, &power);
    IDD_CX_CLIENT_CONFIG config; IDD_CX_CLIENT_CONFIG_INIT(&config);
    config.EvtIddCxAdapterInitFinished = FluxIddAdapterInitFinished;
    config.EvtIddCxParseMonitorDescription = FluxIddParseMonitorDescription;
    config.EvtIddCxAdapterCommitModes = FluxIddAdapterCommitModes;
    config.EvtIddCxMonitorGetDefaultDescriptionModes = FluxIddMonitorGetDefaultModes;
    config.EvtIddCxMonitorQueryTargetModes = FluxIddMonitorQueryTargetModes;
    config.EvtIddCxMonitorAssignSwapChain = FluxIddMonitorAssignSwapChain;
    config.EvtIddCxMonitorUnassignSwapChain = FluxIddMonitorUnassignSwapChain;
    NTSTATUS status = IddCxDeviceInitConfig(deviceInit, &config);
    if (!NT_SUCCESS(status)) {
        OutputDebugStringA("FluxIdd: IddCxDeviceInitConfig failed\n");
        return status;
    }
    WDF_OBJECT_ATTRIBUTES attributes; WDF_OBJECT_ATTRIBUTES_INIT_CONTEXT_TYPE(&attributes, FluxDeviceContext);
    WDFDEVICE device = nullptr;
    status = WdfDeviceCreate(&deviceInit, &attributes, &device);
    if (!NT_SUCCESS(status)) {
        OutputDebugStringA("FluxIdd: WdfDeviceCreate failed\n");
        return status;
    }
    auto* context = FluxGetDeviceContext(device); context->device = device; context->adapter = {};
    status = IddCxDeviceInitialize(device);
    if (!NT_SUCCESS(status)) {
        OutputDebugStringA("FluxIdd: IddCxDeviceInitialize failed\n");
    } else {
        OutputDebugStringA("FluxIdd: IddCxDeviceInitialize success\n");
    }
    return status;
}
NTSTATUS FluxIddDeviceD0Entry(WDFDEVICE device, WDF_POWER_DEVICE_STATE) {
    OutputDebugStringA("FluxIdd: FluxIddDeviceD0Entry entered\n");
    return FluxIddInitializeAdapter(device);
}
