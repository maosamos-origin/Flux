#pragma once
// Windows 11 ARM64 UMDF / IddCx skeleton. No Flux host transport exists yet.
#define NOMINMAX
#include <windows.h>
#include <wudfwdm.h>
#include <wdf.h>
#include <iddcx.h>

constexpr wchar_t kFluxIddFriendlyName[] = L"Flux Virtual Display Adapter";
constexpr wchar_t kFluxIddManufacturer[] = L"Flux";
struct FluxIddMode final { UINT width; UINT height; UINT refreshHz; };
constexpr size_t kFluxIddModeCount = 4;
extern const FluxIddMode kFluxIddModes[kFluxIddModeCount];

struct FluxDeviceContext final { WDFDEVICE device; IDDCX_ADAPTER adapter; };
WDF_DECLARE_CONTEXT_TYPE_WITH_NAME(FluxDeviceContext, FluxGetDeviceContext);
struct SwapChainSession;
struct FluxMonitorContext final { IDDCX_MONITOR monitor; SwapChainSession* activeSession; };
WDF_DECLARE_CONTEXT_TYPE_WITH_NAME(FluxMonitorContext, FluxGetMonitorContext);

extern "C" DRIVER_INITIALIZE DriverEntry;
EVT_WDF_DRIVER_DEVICE_ADD FluxIddDeviceAdd;
EVT_WDF_DEVICE_D0_ENTRY FluxIddDeviceD0Entry;
EVT_IDD_CX_ADAPTER_INIT_FINISHED FluxIddAdapterInitFinished;
EVT_IDD_CX_ADAPTER_COMMIT_MODES FluxIddAdapterCommitModes;
EVT_IDD_CX_PARSE_MONITOR_DESCRIPTION FluxIddParseMonitorDescription;
EVT_IDD_CX_MONITOR_GET_DEFAULT_DESCRIPTION_MODES FluxIddMonitorGetDefaultModes;
EVT_IDD_CX_MONITOR_QUERY_TARGET_MODES FluxIddMonitorQueryTargetModes;
EVT_IDD_CX_MONITOR_ASSIGN_SWAPCHAIN FluxIddMonitorAssignSwapChain;
EVT_IDD_CX_MONITOR_UNASSIGN_SWAPCHAIN FluxIddMonitorUnassignSwapChain;

NTSTATUS FluxIddInitializeAdapter(WDFDEVICE device);
NTSTATUS FluxIddCreateAndArriveMonitor(IDDCX_ADAPTER adapter);
IDDCX_MONITOR_MODE FluxIddMakeMonitorMode(const FluxIddMode& mode, IDDCX_MONITOR_MODE_ORIGIN origin = IDDCX_MONITOR_MODE_ORIGIN_DRIVER);
IDDCX_TARGET_MODE FluxIddMakeTargetMode(const FluxIddMode& mode);
void FluxIddStopWorker(FluxMonitorContext* ctx);
