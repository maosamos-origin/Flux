#include "FluxIdd.h"
#include <d3d11.h>
#include <dxgi1_2.h>
#include <wrl/client.h>
#include <stdio.h>
#include <memory>

#pragma comment(lib, "d3d11.lib")
#pragma comment(lib, "dxgi.lib")

using Microsoft::WRL::ComPtr;

//
// SwapChainSession encapsulates the complete lifecycle of one swapchain processing instance.
//
// OWNERSHIP MODEL:
// - Reference Count = 2 at creation:
//     1. Monitor Reference (held by FluxMonitorContext::activeSession)
//     2. Worker Reference  (held by the background thread FluxIddWorkerThread)
//
// RELEASE RULES:
// - Normal Shutdown (WAIT_OBJECT_0):
//     StopWorker waits up to 5000 ms.
//     Worker breaks loop, releases its worker reference, and terminates.
//     StopWorker reclaims hThread, hTerminateEvent, and hSwapChain via WdfObjectDelete.
//     StopWorker drops the monitor reference (refCount drops to 0 -> session deleted).
// - Timeout Shutdown (WAIT_TIMEOUT / WAIT_FAILED):
//     Worker is still running after 5000 ms.
//     StopWorker sets cleanupDelegatedToWorker = 1.
//     StopWorker drops the monitor reference so FluxMonitorContext can be destroyed safely.
//     When the worker eventually exits, it detects cleanupDelegatedToWorker == 1,
//     executes the delayed cleanup of hSwapChain, hTerminateEvent, and hThread itself,
//     and drops the worker reference (refCount drops to 0 -> session deleted).
//
struct SwapChainSession final {
    volatile LONG refCount;
    volatile LONG cleanupDelegatedToWorker;
    IDDCX_SWAPCHAIN hSwapChain;
    HANDLE hTerminateEvent;
    HANDLE hNextSurfaceAvailable;
    HANDLE hThread;
    LUID renderAdapterLuid;
    ComPtr<ID3D11Device> d3dDevice;
    ComPtr<IDXGIDevice> dxgiDevice;
    volatile LONG64 frameAcquireCount;
    volatile LONG64 frameProcessedCount;
    volatile LONG64 frameProcessingErrorCount;
    volatile LONG lastWidth;
    volatile LONG lastHeight;
    volatile LONG lastFormat;
    volatile LONG setDeviceCalled;
    volatile LONG setDeviceHr;
};

static SwapChainSession* CreateSwapChainSession() {
    auto* s = new (std::nothrow) SwapChainSession();
    if (s) {
        // Initial reference owned by FluxMonitorContext
        s->refCount = 1;
        s->cleanupDelegatedToWorker = 0;
        s->hSwapChain = nullptr;
        s->hTerminateEvent = nullptr;
        s->hNextSurfaceAvailable = nullptr;
        s->hThread = nullptr;
        s->renderAdapterLuid = {};
        s->frameAcquireCount = 0;
        s->frameProcessedCount = 0;
        s->frameProcessingErrorCount = 0;
        s->lastWidth = 0;
        s->lastHeight = 0;
        s->lastFormat = 0;
        s->setDeviceCalled = 0;
        s->setDeviceHr = 0;
    }
    return s;
}

static void AddRefSession(SwapChainSession* s) {
    if (s) {
        InterlockedIncrement(&s->refCount);
    }
}

static void ReleaseSession(SwapChainSession*& s) {
    if (s) {
        if (InterlockedDecrement(&s->refCount) == 0) {
            delete s;
        }
        s = nullptr;
    }
}

static void WriteDiagnosticStatus(const char* state, UINT width, UINT height, UINT format,
                                  LONG64 acq, LONG64 proc, LONG64 err,
                                  LONG setDeviceCalled = 0, LONG setDeviceHr = 0) {
    HANDLE hFile = CreateFileA("C:\\Users\\Public\\flux_swapchain_status.txt",
                               GENERIC_WRITE, FILE_SHARE_READ, nullptr,
                               CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (hFile != INVALID_HANDLE_VALUE) {
        char buf[768];
        int len = sprintf_s(buf, sizeof(buf),
            "SWAPCHAIN_ASSIGN_CALLED=YES\r\n"
            "SWAPCHAIN_WORKER_STARTED=YES\r\n"
            "SET_DEVICE_CALLED=%s\r\n"
            "SET_DEVICE_HR=0x%08X\r\n"
            "SURFACE_AVAILABLE_SIGNAL_SEEN=%s\r\n"
            "FRAME_ACQUIRE_SUCCESS=%s\r\n"
            "FRAME_ACQUIRE_COUNT=%lld\r\n"
            "FRAME_PROCESSED_COUNT=%lld\r\n"
            "FRAME_PROCESSING_ERROR_COUNT=%lld\r\n"
            "FRAME_DELIVERY=%s\r\n"
            "FRAME_WIDTH=%u\r\n"
            "FRAME_HEIGHT=%u\r\n"
            "FRAME_FORMAT=%u\r\n"
            "SWAPCHAIN_FRAME_COUNT=%lld\r\n"
            "FINISHED_PROCESSING_CALLED=%s\r\n"
            "SWAPCHAIN_UNASSIGN_CALLED=%s\r\n"
            "SWAPCHAIN_WORKER_STOPPED=%s\r\n"
            "WORKER_STATE=%s\r\n",
            setDeviceCalled ? "YES" : "NO",
            static_cast<UINT>(setDeviceHr),
            proc > 0 ? "YES" : (acq > 0 ? "YES" : "WAITING"),
            acq > 0 ? "YES" : "NO",
            acq,
            proc,
            err,
            proc > 0 ? "YES" : "NO",
            width, height, format,
            proc,
            proc > 0 ? "YES" : "NO",
            strcmp(state, "STOPPED") == 0 ? "YES" : "NO",
            strcmp(state, "STOPPED") == 0 ? "YES" : "NO",
            state);
        if (len > 0) {
            DWORD written = 0;
            WriteFile(hFile, buf, static_cast<DWORD>(len), &written, nullptr);
        }
        CloseHandle(hFile);
    }
}

static HRESULT CreateRenderDevice(LUID renderAdapterLuid, ComPtr<ID3D11Device>& device, ComPtr<IDXGIDevice>& dxgiDevice) {
    ComPtr<IDXGIFactory1> dxgiFactory;
    HRESULT hr = CreateDXGIFactory1(IID_PPV_ARGS(&dxgiFactory));
    if (FAILED(hr)) {
        return hr;
    }

    ComPtr<IDXGIAdapter1> matchedAdapter;
    for (UINT i = 0;; ++i) {
        ComPtr<IDXGIAdapter1> adapter;
        if (dxgiFactory->EnumAdapters1(i, &adapter) == DXGI_ERROR_NOT_FOUND) {
            break;
        }
        DXGI_ADAPTER_DESC1 desc = {};
        if (SUCCEEDED(adapter->GetDesc1(&desc))) {
            if (desc.AdapterLuid.LowPart == renderAdapterLuid.LowPart &&
                desc.AdapterLuid.HighPart == renderAdapterLuid.HighPart) {
                matchedAdapter = adapter;
                break;
            }
        }
    }

    if (!matchedAdapter) {
        char msg[128];
        sprintf_s(msg, sizeof(msg), "FluxIdd: RenderAdapterLuid 0x%08X:0x%08X not found\n",
                  renderAdapterLuid.HighPart, renderAdapterLuid.LowPart);
        OutputDebugStringA(msg);
        return HRESULT_FROM_WIN32(ERROR_NOT_FOUND);
    }

    D3D_FEATURE_LEVEL featureLevels[] = {
        D3D_FEATURE_LEVEL_11_1,
        D3D_FEATURE_LEVEL_11_0,
        D3D_FEATURE_LEVEL_10_1,
        D3D_FEATURE_LEVEL_10_0,
        D3D_FEATURE_LEVEL_9_3,
        D3D_FEATURE_LEVEL_9_1
    };

    ComPtr<ID3D11DeviceContext> d3dContext;
    hr = D3D11CreateDevice(
        matchedAdapter.Get(),
        D3D_DRIVER_TYPE_UNKNOWN,
        nullptr,
        D3D11_CREATE_DEVICE_BGRA_SUPPORT,
        featureLevels,
        ARRAYSIZE(featureLevels),
        D3D11_SDK_VERSION,
        &device,
        nullptr,
        &d3dContext
    );
    if (FAILED(hr)) {
        char msg[128];
        sprintf_s(msg, sizeof(msg), "FluxIdd: D3D11CreateDevice failed on matched adapter: 0x%08X\n", hr);
        OutputDebugStringA(msg);
        return hr;
    }

    hr = device.As(&dxgiDevice);
    if (FAILED(hr)) {
        OutputDebugStringA("FluxIdd: Query IDXGIDevice failed\n");
        return hr;
    }

    return S_OK;
}

static DWORD WINAPI FluxIddWorkerThread(LPVOID param) {
    auto* session = reinterpret_cast<SwapChainSession*>(param);
    if (!session) {
        return 0;
    }

    OutputDebugStringA("FluxIdd: FluxIddWorkerThread entered\n");

    IDDCX_SWAPCHAIN hSwapChain = session->hSwapChain;
    // hTerminateEvent placed at index 0 guarantees termination priority over hNextSurfaceAvailable at index 1
    HANDLE waitHandles[2] = { session->hTerminateEvent, session->hNextSurfaceAvailable };

    // Priority Check 1: Explicit termination check before starting D3D setup
    if (WaitForSingleObject(session->hTerminateEvent, 0) == WAIT_OBJECT_0) {
        OutputDebugStringA("FluxIdd: Worker detected termination priority signal before device creation\n");
        goto Cleanup;
    }

    // 1. CreateRenderDevice(session->renderAdapterLuid, ...)
    {
        ComPtr<ID3D11Device> d3dDevice;
        ComPtr<IDXGIDevice> dxgiDevice;
        HRESULT hr = CreateRenderDevice(session->renderAdapterLuid, d3dDevice, dxgiDevice);
        if (FAILED(hr)) {
            char msg[128];
            sprintf_s(msg, sizeof(msg), "FluxIdd: Worker CreateRenderDevice failed: 0x%08X\n", hr);
            OutputDebugStringA(msg);
            WriteDiagnosticStatus("DEVICE_CREATION_FAILED", 0, 0, 0, 0, 0, 1, 0, hr);
            goto Cleanup;
        }

        session->d3dDevice = d3dDevice;
        session->dxgiDevice = dxgiDevice;
    }

    // Priority Check 2: Check termination again before SetDevice
    if (WaitForSingleObject(session->hTerminateEvent, 0) == WAIT_OBJECT_0) {
        OutputDebugStringA("FluxIdd: Worker detected termination priority signal before SetDevice\n");
        goto Cleanup;
    }

    // 2. IddCxSwapChainSetDevice(session->hSwapChain, &setDevice)
    {
        IDARG_IN_SWAPCHAINSETDEVICE setDevice = {};
        setDevice.pDevice = session->dxgiDevice.Get();
        HRESULT hr = IddCxSwapChainSetDevice(hSwapChain, &setDevice);
        InterlockedExchange(&session->setDeviceCalled, 1);
        InterlockedExchange(&session->setDeviceHr, static_cast<LONG>(hr));

        if (FAILED(hr)) {
            char msg[128];
            sprintf_s(msg, sizeof(msg), "FluxIdd: Worker IddCxSwapChainSetDevice failed: 0x%08X\n", hr);
            OutputDebugStringA(msg);
            WriteDiagnosticStatus("SET_DEVICE_FAILED", 0, 0, 0, 0, 0, 1, 1, hr);
            goto Cleanup;
        }
        OutputDebugStringA("FluxIdd: Worker IddCxSwapChainSetDevice succeeded\n");
        WriteDiagnosticStatus("RUNNING", 0, 0, 0, 0, 0, 0, 1, hr);
    }

    for (;;) {
        // Priority Check 1: Explicit termination check before acquiring prevents starvation under continuous arrival
        if (WaitForSingleObject(session->hTerminateEvent, 0) == WAIT_OBJECT_0) {
            OutputDebugStringA("FluxIdd: Worker detected termination priority signal\n");
            break;
        }

        IDARG_OUT_RELEASEANDACQUIREBUFFER buffer = {};
        HRESULT hr = IddCxSwapChainReleaseAndAcquireBuffer(hSwapChain, &buffer);

        if (hr == E_PENDING) {
            DWORD waitRes = WaitForMultipleObjects(2, waitHandles, FALSE, INFINITE);
            if (waitRes == WAIT_OBJECT_0) {
                // Index 0: hTerminateEvent takes priority even if index 1 was also signaled
                OutputDebugStringA("FluxIdd: Worker received termination signal\n");
                break;
            } else if (waitRes == WAIT_OBJECT_0 + 1) {
                // Index 1: hNextSurfaceAvailable
                if (InterlockedCompareExchange64(&session->frameAcquireCount, 0, 0) == 0) {
                    OutputDebugStringA("FluxIdd: SURFACE_AVAILABLE_SIGNAL_SEEN\n");
                }
                continue;
            } else {
                DWORD err = GetLastError();
                char msg[128];
                sprintf_s(msg, sizeof(msg), "FluxIdd: WaitForMultipleObjects error: %lu\n", err);
                OutputDebugStringA(msg);
                break;
            }
        } else if (SUCCEEDED(hr)) {
            // Buffer acquired successfully: frame lifecycle MUST reach FinishedProcessingFrame
            LONG64 acq = InterlockedIncrement64(&session->frameAcquireCount);

            bool surfaceValid = false;
            UINT width = 0;
            UINT height = 0;
            UINT format = 0;

            if (buffer.MetaData.pSurface) {
                ComPtr<IDXGIResource> dxgiResource;
                dxgiResource.Attach(buffer.MetaData.pSurface);

                ComPtr<ID3D11Texture2D> texture;
                if (SUCCEEDED(dxgiResource.As(&texture)) && texture) {
                    D3D11_TEXTURE2D_DESC desc = {};
                    texture->GetDesc(&desc);
                    width = desc.Width;
                    height = desc.Height;
                    format = static_cast<UINT>(desc.Format);

                    if (width > 0 && height > 0 && desc.Format != DXGI_FORMAT_UNKNOWN) {
                        surfaceValid = true;
                        InterlockedExchange(&session->lastWidth, static_cast<LONG>(width));
                        InterlockedExchange(&session->lastHeight, static_cast<LONG>(height));
                        InterlockedExchange(&session->lastFormat, static_cast<LONG>(format));
                    }
                }
                // Release the COM reference held by Attach
                dxgiResource.Reset();
            }

            if (!surfaceValid) {
                InterlockedIncrement64(&session->frameProcessingErrorCount);
                OutputDebugStringA("FluxIdd: Acquired surface invalid or metadata empty\n");
            }

            // CRITICAL CONTRACT: Regardless of surface validity, if ReleaseAndAcquireBuffer succeeded,
            // the frame lifecycle MUST complete by calling FinishedProcessingFrame exactly once.
            HRESULT finishHr = IddCxSwapChainFinishedProcessingFrame(hSwapChain);
            if (FAILED(finishHr)) {
                InterlockedIncrement64(&session->frameProcessingErrorCount);
                char msg[128];
                sprintf_s(msg, sizeof(msg), "FluxIdd: FinishedProcessingFrame failed: 0x%08X\n", finishHr);
                OutputDebugStringA(msg);
                break;
            }

            if (surfaceValid) {
                LONG64 proc = InterlockedIncrement64(&session->frameProcessedCount);

                if (proc == 1 || proc == 2 || proc == 10 || (proc % 60 == 0)) {
                    LONG64 err = InterlockedCompareExchange64(&session->frameProcessingErrorCount, 0, 0);
                    char msg[256];
                    sprintf_s(msg, sizeof(msg),
                        "FluxIdd: FRAME_DELIVERY_SUCCESS width=%u height=%u format=%u acquire=%lld processed=%lld errors=%lld\n",
                        width, height, format, acq, proc, err);
                    OutputDebugStringA(msg);
                    WriteDiagnosticStatus("ACTIVE", width, height, format, acq, proc, err, 1, session->setDeviceHr);
                }
            } else {
                // Surface was invalid: frame lifecycle completed cleanly via FinishedProcessingFrame, now terminate loop
                break;
            }
        } else {
            // Fatal acquire failure: Buffer was NOT acquired, so FinishedProcessingFrame must NOT be called.
            InterlockedIncrement64(&session->frameProcessingErrorCount);
            char msg[128];
            sprintf_s(msg, sizeof(msg), "FluxIdd: ReleaseAndAcquireBuffer fatal error: 0x%08X\n", hr);
            OutputDebugStringA(msg);
            break;
        }
    }

Cleanup:
    // Delayed cleanup check: if StopWorker timed out, worker performs the delegated cleanup
    if (InterlockedCompareExchange(&session->cleanupDelegatedToWorker, 0, 0) == 1) {
        OutputDebugStringA("FluxIdd: Worker executing delegated resource cleanup post-timeout\n");
        if (session->hTerminateEvent) {
            CloseHandle(session->hTerminateEvent);
            session->hTerminateEvent = nullptr;
        }
        if (session->hThread) {
            CloseHandle(session->hThread);
            session->hThread = nullptr;
        }
        if (session->hSwapChain) {
            WdfObjectDelete(session->hSwapChain);
            session->hSwapChain = nullptr;
        }
        session->hNextSurfaceAvailable = nullptr;
    }

    // Release worker reference (worker ownership ends)
    ReleaseSession(session);
    return 0;
}

void FluxIddStopWorker(FluxMonitorContext* ctx) {
    if (!ctx || !ctx->activeSession) {
        return;
    }

    auto* session = ctx->activeSession;

    if (session->hThread) {
        // Signal worker to terminate
        if (session->hTerminateEvent) {
            SetEvent(session->hTerminateEvent);
        }

        DWORD waitRes = WaitForSingleObject(session->hThread, 5000);
        if (waitRes == WAIT_OBJECT_0) {
            // Worker thread has exited cleanly. StopWorker cleans up resources immediately.
            CloseHandle(session->hThread);
            session->hThread = nullptr;

            if (session->hTerminateEvent) {
                CloseHandle(session->hTerminateEvent);
                session->hTerminateEvent = nullptr;
            }

            if (session->hSwapChain) {
                WdfObjectDelete(session->hSwapChain);
                session->hSwapChain = nullptr;
            }

            session->hNextSurfaceAvailable = nullptr;
            OutputDebugStringA("FluxIdd: SWAPCHAIN_WORKER_STOPPED\n");

            UINT w = static_cast<UINT>(InterlockedCompareExchange(&session->lastWidth, 0, 0));
            UINT h = static_cast<UINT>(InterlockedCompareExchange(&session->lastHeight, 0, 0));
            UINT f = static_cast<UINT>(InterlockedCompareExchange(&session->lastFormat, 0, 0));
            LONG64 acq = InterlockedCompareExchange64(&session->frameAcquireCount, 0, 0);
            LONG64 proc = InterlockedCompareExchange64(&session->frameProcessedCount, 0, 0);
            LONG64 err = InterlockedCompareExchange64(&session->frameProcessingErrorCount, 0, 0);
            LONG sdc = InterlockedCompareExchange(&session->setDeviceCalled, 0, 0);
            LONG sdhr = InterlockedCompareExchange(&session->setDeviceHr, 0, 0);
            WriteDiagnosticStatus("STOPPED", w, h, f, acq, proc, err, sdc, sdhr);

            // Release the monitor's reference
            ReleaseSession(ctx->activeSession);
        } else if (waitRes == WAIT_TIMEOUT) {
            // Worker is still executing: delegate resource cleanup to the worker upon delayed exit
            OutputDebugStringA("FluxIdd: WARNING: Worker termination TIMEOUT; delegating cleanup to worker\n");
            InterlockedExchange(&session->cleanupDelegatedToWorker, 1);
            // Drop monitor reference so FluxMonitorContext can be destroyed without leaking SwapChainSession
            ReleaseSession(ctx->activeSession);
        } else {
            DWORD err = GetLastError();
            char msg[128];
            sprintf_s(msg, sizeof(msg), "FluxIdd: WARNING: WaitForSingleObject WAIT_FAILED err=%lu\n", err);
            OutputDebugStringA(msg);
            InterlockedExchange(&session->cleanupDelegatedToWorker, 1);
            ReleaseSession(ctx->activeSession);
        }
    } else {
        // No thread was started (e.g. failure prior to CreateThread)
        if (session->hTerminateEvent) {
            CloseHandle(session->hTerminateEvent);
            session->hTerminateEvent = nullptr;
        }
        if (session->hSwapChain) {
            WdfObjectDelete(session->hSwapChain);
            session->hSwapChain = nullptr;
        }
        session->hNextSurfaceAvailable = nullptr;
        ReleaseSession(ctx->activeSession);
    }
}

NTSTATUS FluxIddMonitorAssignSwapChain(IDDCX_MONITOR monitor, const IDARG_IN_SETSWAPCHAIN* args) {
    OutputDebugStringA("FluxIdd: SWAPCHAIN_ASSIGN_CALLED\n");
    auto* ctx = FluxGetMonitorContext(monitor);
    if (!ctx) {
        return STATUS_INVALID_PARAMETER;
    }

    // Stop any existing worker session
    FluxIddStopWorker(ctx);

    if (ctx->activeSession != nullptr) {
        // A prior worker session is still active post-timeout; block replacement swapchain
        OutputDebugStringA("FluxIdd: Rejecting replacement swapchain: prior worker still active\n");
        WdfObjectDelete(args->hSwapChain);
        return STATUS_SUCCESS;
    }

    auto* session = CreateSwapChainSession();
    if (!session) {
        OutputDebugStringA("FluxIdd: Failed to allocate SwapChainSession\n");
        WdfObjectDelete(args->hSwapChain);
        return STATUS_SUCCESS;
    }

    session->hTerminateEvent = CreateEvent(nullptr, TRUE, FALSE, nullptr);
    if (!session->hTerminateEvent) {
        OutputDebugStringA("FluxIdd: CreateEvent failed for hTerminateEvent\n");
        ReleaseSession(session);
        WdfObjectDelete(args->hSwapChain);
        return STATUS_SUCCESS;
    }

    session->hSwapChain = args->hSwapChain;
    session->hNextSurfaceAvailable = args->hNextSurfaceAvailable;
    session->renderAdapterLuid = args->RenderAdapterLuid;

    // Acquire worker thread reference (refCount = 2)
    AddRefSession(session);

    HANDLE hThread = CreateThread(nullptr, 0, FluxIddWorkerThread, session, 0, nullptr);
    if (!hThread) {
        OutputDebugStringA("FluxIdd: CreateThread failed for worker\n");
        ReleaseSession(session); // release worker reference
        CloseHandle(session->hTerminateEvent);
        session->hTerminateEvent = nullptr;
        WdfObjectDelete(session->hSwapChain);
        session->hSwapChain = nullptr;
        ReleaseSession(session); // release monitor reference
        return STATUS_SUCCESS;
    }

    session->hThread = hThread;
    ctx->activeSession = session;

    OutputDebugStringA("FluxIdd: SWAPCHAIN_WORKER_STARTED\n");
    WriteDiagnosticStatus("STARTING", 0, 0, 0, 0, 0, 0, 0, 0);

    return STATUS_SUCCESS;
}

NTSTATUS FluxIddMonitorUnassignSwapChain(IDDCX_MONITOR monitor) {
    OutputDebugStringA("FluxIdd: SWAPCHAIN_UNASSIGN_CALLED\n");
    auto* ctx = FluxGetMonitorContext(monitor);
    if (ctx) {
        FluxIddStopWorker(ctx);
    }
    return STATUS_SUCCESS;
}
