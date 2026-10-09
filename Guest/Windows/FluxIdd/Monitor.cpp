#include "FluxIdd.h"

const FluxIddMode kFluxIddModes[kFluxIddModeCount] = {
    { 800,  600, 60},
    {1280,  720, 60},
    {1600,  900, 60},
    {1920, 1080, 60}
};

// 128-byte valid EDID block advertising "Flux Display" with Full HD 1080p60 and 800x600 capabilities
static const BYTE kFluxIddEdidBlock[128] = {
    0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x10, 0xAC, 0xE6, 0xD0, 0x55, 0x5A, 0x4A, 0x30,
    0x24, 0x1D, 0x01, 0x04, 0xA5, 0x3C, 0x22, 0x78, 0xFB, 0x6C, 0xE5, 0xA5, 0x55, 0x50, 0xA0, 0x23,
    0x0B, 0x50, 0x54, 0x00, 0x02, 0x00, 0xD1, 0xC0, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01,
    0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x58, 0xE3, 0x00, 0xA0, 0xA0, 0xA0, 0x29, 0x50, 0x30, 0x20,
    0x35, 0x00, 0x55, 0x50, 0x21, 0x00, 0x00, 0x1A, 0x00, 0x00, 0x00, 0xFF, 0x00, 0x37, 0x4A, 0x51,
    0x58, 0x42, 0x59, 0x32, 0x0A, 0x20, 0x20, 0x20, 0x20, 0x20, 0x00, 0x00, 0x00, 0xFC, 0x00, 0x46,
    0x6C, 0x75, 0x78, 0x20, 0x44, 0x69, 0x73, 0x70, 0x6C, 0x61, 0x79, 0x0A, 0x00, 0x00, 0x00, 0xFD,
    0x00, 0x28, 0x9B, 0xFA, 0xFA, 0x40, 0x01, 0x0A, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x00, 0x0E
};

static void FillSignalInfo(DISPLAYCONFIG_VIDEO_SIGNAL_INFO* signal, const FluxIddMode& mode, bool monitorMode) {
    signal->totalSize.cx = signal->activeSize.cx = mode.width;
    signal->totalSize.cy = signal->activeSize.cy = mode.height;
    signal->AdditionalSignalInfo.vSyncFreqDivider = monitorMode ? 0 : 1;
    signal->AdditionalSignalInfo.videoStandard = 255;
    signal->vSyncFreq.Numerator = mode.refreshHz;
    signal->vSyncFreq.Denominator = 1;
    signal->hSyncFreq.Numerator = mode.refreshHz * mode.height;
    signal->hSyncFreq.Denominator = 1;
    signal->scanLineOrdering = DISPLAYCONFIG_SCANLINE_ORDERING_PROGRESSIVE;
    signal->pixelRate = static_cast<UINT64>(mode.refreshHz) * mode.width * mode.height;
}

IDDCX_MONITOR_MODE FluxIddMakeMonitorMode(const FluxIddMode& mode, IDDCX_MONITOR_MODE_ORIGIN origin) {
    IDDCX_MONITOR_MODE out = {};
    out.Size = sizeof(out);
    out.Origin = origin;
    FillSignalInfo(&out.MonitorVideoSignalInfo, mode, true);
    return out;
}

IDDCX_TARGET_MODE FluxIddMakeTargetMode(const FluxIddMode& mode) {
    IDDCX_TARGET_MODE out = {};
    out.Size = sizeof(out);
    FillSignalInfo(&out.TargetVideoSignalInfo.targetVideoSignalInfo, mode, false);
    return out;
}

NTSTATUS FluxIddCreateAndArriveMonitor(IDDCX_ADAPTER adapter) {
    OutputDebugStringA("FluxIdd: FluxIddCreateAndArriveMonitor entered\n");
    WDF_OBJECT_ATTRIBUTES attributes;
    WDF_OBJECT_ATTRIBUTES_INIT_CONTEXT_TYPE(&attributes, FluxMonitorContext);
    attributes.EvtCleanupCallback = [](WDFOBJECT obj) {
        auto* monCtx = FluxGetMonitorContext(obj);
        if (monCtx) {
            FluxIddStopWorker(monCtx);
        }
    };

    IDDCX_MONITOR_INFO monitorInfo = {};
    monitorInfo.Size = sizeof(monitorInfo);
    monitorInfo.MonitorType = DISPLAYCONFIG_OUTPUT_TECHNOLOGY_HDMI;
    monitorInfo.ConnectorIndex = 0;
    monitorInfo.MonitorDescription.Size = sizeof(monitorInfo.MonitorDescription);
    monitorInfo.MonitorDescription.Type = IDDCX_MONITOR_DESCRIPTION_TYPE_EDID;
    monitorInfo.MonitorDescription.DataSize = sizeof(kFluxIddEdidBlock);
    monitorInfo.MonitorDescription.pData = const_cast<BYTE*>(kFluxIddEdidBlock);

    static const GUID kFluxMonitorContainerId = { 0x9b34a9e2, 0x7d7a, 0x4d3b, { 0x96, 0x42, 0x1c, 0x2d, 0xf3, 0x2a, 0xa0, 0x01 } };
    monitorInfo.MonitorContainerId = kFluxMonitorContainerId;

    IDARG_IN_MONITORCREATE input = {};
    input.ObjectAttributes = &attributes;
    input.pMonitorInfo = &monitorInfo;
    IDARG_OUT_MONITORCREATE output = {};

    NTSTATUS status = IddCxMonitorCreate(adapter, &input, &output);
    if (!NT_SUCCESS(status)) {
        OutputDebugStringA("FluxIdd: IddCxMonitorCreate failed\n");
        return status;
    }
    OutputDebugStringA("FluxIdd: IddCxMonitorCreate success\n");

    auto* monCtx = FluxGetMonitorContext(output.MonitorObject);
    monCtx->monitor = output.MonitorObject;
    monCtx->activeSession = nullptr;

    IDARG_OUT_MONITORARRIVAL arrival = {};
    status = IddCxMonitorArrival(output.MonitorObject, &arrival);
    if (!NT_SUCCESS(status)) {
        OutputDebugStringA("FluxIdd: IddCxMonitorArrival failed\n");
    } else {
        OutputDebugStringA("FluxIdd: IddCxMonitorArrival success\n");
    }
    return status;
}

NTSTATUS FluxIddMonitorGetDefaultModes(IDDCX_MONITOR, const IDARG_IN_GETDEFAULTDESCRIPTIONMODES* input, IDARG_OUT_GETDEFAULTDESCRIPTIONMODES* output) {
    OutputDebugStringA("FluxIdd: FluxIddMonitorGetDefaultModes entered\n");
    output->DefaultMonitorModeBufferOutputCount = static_cast<UINT>(kFluxIddModeCount);
    output->PreferredMonitorModeIdx = 0;
    if (input->DefaultMonitorModeBufferInputCount < kFluxIddModeCount) {
        return (input->DefaultMonitorModeBufferInputCount > 0) ? STATUS_BUFFER_TOO_SMALL : STATUS_SUCCESS;
    }
    for (size_t i = 0; i < kFluxIddModeCount; ++i) {
        input->pDefaultMonitorModes[i] = FluxIddMakeMonitorMode(kFluxIddModes[i], IDDCX_MONITOR_MODE_ORIGIN_DRIVER);
    }
    return STATUS_SUCCESS;
}

NTSTATUS FluxIddMonitorQueryTargetModes(IDDCX_MONITOR, const IDARG_IN_QUERYTARGETMODES* input, IDARG_OUT_QUERYTARGETMODES* output) {
    OutputDebugStringA("FluxIdd: FluxIddMonitorQueryTargetModes entered\n");
    output->TargetModeBufferOutputCount = static_cast<UINT>(kFluxIddModeCount);
    if (input->TargetModeBufferInputCount < kFluxIddModeCount) {
        return (input->TargetModeBufferInputCount > 0) ? STATUS_BUFFER_TOO_SMALL : STATUS_SUCCESS;
    }
    for (size_t i = 0; i < kFluxIddModeCount; ++i) {
        input->pTargetModes[i] = FluxIddMakeTargetMode(kFluxIddModes[i]);
    }
    return STATUS_SUCCESS;
}

NTSTATUS FluxIddParseMonitorDescription(const IDARG_IN_PARSEMONITORDESCRIPTION* input, IDARG_OUT_PARSEMONITORDESCRIPTION* output) {
    OutputDebugStringA("FluxIdd: FluxIddParseMonitorDescription entered\n");
    output->MonitorModeBufferOutputCount = static_cast<UINT>(kFluxIddModeCount);
    output->PreferredMonitorModeIdx = 0;
    if (input->MonitorModeBufferInputCount < kFluxIddModeCount) {
        return (input->MonitorModeBufferInputCount > 0) ? STATUS_BUFFER_TOO_SMALL : STATUS_SUCCESS;
    }
    for (size_t i = 0; i < kFluxIddModeCount; ++i) {
        input->pMonitorModes[i] = FluxIddMakeMonitorMode(kFluxIddModes[i], IDDCX_MONITOR_MODE_ORIGIN_MONITORDESCRIPTOR);
    }
    return STATUS_SUCCESS;
}
