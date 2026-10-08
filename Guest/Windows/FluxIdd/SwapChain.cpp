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
#pragma pack(push, 1)
struct FluxFrameTransportHeader {
    char magic[8];          // "FLXFTRAN"
    UINT32 version;         // 1
    UINT32 sequence;        // 1, 2, 3...
    UINT32 width;           // 800
    UINT32 height;          // 600
    UINT32 stride;          // 3200
    UINT32 pixelFormat;     // 87 (DXGI_FORMAT_B8G8R8A8_UNORM)
    UINT32 dataSize;        // 1,920,000
    UINT32 status;          // 2 (READY)
    UINT32 checksum;        // 32-bit additive checksum of pixel bytes
    UINT32 pixel0;          // sample pixel at (0, 0)
    UINT32 pixelCenter;     // sample pixel at (width/2, height/2)
    UINT32 pixelLast;       // sample pixel at (width-1, height-1)
    UINT32 reserved;        // 0
};
#pragma pack(pop)

struct SwapChainSession final {
    volatile LONG refCount;
    volatile LONG cleanupDelegatedToWorker;
    IDDCX_SWAPCHAIN hSwapChain;
    HANDLE hTerminateEvent;
    HANDLE hNextSurfaceAvailable;
    HANDLE hThread;
    HANDLE hSerialPort;
    LUID renderAdapterLuid;
    ComPtr<ID3D11Device> d3dDevice;
    ComPtr<IDXGIDevice> dxgiDevice;
    ComPtr<ID3D11Texture2D> stagingTexture;
    UINT stagingWidth;
    UINT stagingHeight;
    volatile LONG64 frameAcquireCount;
    volatile LONG64 frameProcessedCount;
    volatile LONG64 frameReleaseCount;
    volatile LONG64 surfaceSignalCount;
    volatile LONG64 frameProcessingErrorCount;
    volatile LONG lastWidth;
    volatile LONG lastHeight;
    volatile LONG lastFormat;
    volatile LONG firstFrameWidth;
    volatile LONG firstFrameHeight;
    volatile LONG setDeviceCalled;
    volatile LONG setDeviceHr;
    volatile LONG transportSequence;
    volatile LONG transportFrameCount;
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
        s->hSerialPort = INVALID_HANDLE_VALUE;
        s->stagingTexture = nullptr;
        s->stagingWidth = 0;
        s->stagingHeight = 0;
        s->renderAdapterLuid = {};
        s->frameAcquireCount = 0;
        s->frameProcessedCount = 0;
        s->frameReleaseCount = 0;
        s->surfaceSignalCount = 0;
        s->frameProcessingErrorCount = 0;
        s->lastWidth = 0;
        s->lastHeight = 0;
        s->lastFormat = 0;
        s->firstFrameWidth = 0;
        s->firstFrameHeight = 0;
        s->setDeviceCalled = 0;
        s->setDeviceHr = 0;
        s->transportSequence = 0;
        s->transportFrameCount = 0;
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
            if (s->hSerialPort != INVALID_HANDLE_VALUE) {
                CloseHandle(s->hSerialPort);
                s->hSerialPort = INVALID_HANDLE_VALUE;
            }
            s->stagingTexture.Reset();
            delete s;
        }
        s = nullptr;
    }
}

static void WriteDiagnosticStatus(const char* state, UINT width, UINT height, UINT format,
                                  LONG64 acq, LONG64 proc, LONG64 rel, LONG64 sig, LONG64 err,
                                  LONG setDeviceCalled = 0, LONG setDeviceHr = 0,
                                  UINT firstWidth = 0, UINT firstHeight = 0,
                                  LONG transSeq = 0, LONG transCount = 0) {
    HANDLE hFile = CreateFileA("C:\\Users\\Public\\flux_swapchain_status.txt",
                               GENERIC_WRITE, FILE_SHARE_READ, nullptr,
                               CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (hFile != INVALID_HANDLE_VALUE) {
        char buf[1024];
        int len = sprintf_s(buf, sizeof(buf),
            "SWAPCHAIN_ASSIGN_CALLED=YES\r\n"
            "SWAPCHAIN_WORKER_STARTED=YES\r\n"
            "SET_DEVICE_CALLED=%s\r\n"
            "SET_DEVICE_HR=0x%08X\r\n"
            "SURFACE_AVAILABLE_SIGNAL_SEEN=%s\r\n"
            "SURFACE_SIGNAL_COUNT=%lld\r\n"
            "FRAME_ACQUIRE_SUCCESS=%s\r\n"
            "FRAME_ACQUIRE_COUNT=%lld\r\n"
            "FRAME_RELEASE_COUNT=%lld\r\n"
            "FRAME_PROCESSED_COUNT=%lld\r\n"
            "FRAME_PROCESSING_ERROR_COUNT=%lld\r\n"
            "FRAME_DELIVERY=%s\r\n"
            "FIRST_FRAME_WIDTH=%u\r\n"
            "FIRST_FRAME_HEIGHT=%u\r\n"
            "FRAME_WIDTH=%u\r\n"
            "FRAME_HEIGHT=%u\r\n"
            "FRAME_FORMAT=%u\r\n"
            "SWAPCHAIN_FRAME_COUNT=%lld\r\n"
            "FINISHED_PROCESSING_CALLED=%s\r\n"
            "FRAME_TRANSPORT_CONNECTED=%s\r\n"
            "FRAME_TRANSPORT_SEQUENCE=%ld\r\n"
            "FRAME_TRANSPORT_FRAME_COUNT=%ld\r\n"
            "SWAPCHAIN_UNASSIGN_CALLED=%s\r\n"
            "SWAPCHAIN_WORKER_STOPPED=%s\r\n"
            "WORKER_STATE=%s\r\n",
            setDeviceCalled ? "YES" : "NO",
            static_cast<UINT>(setDeviceHr),
            (sig > 0 || acq > 0) ? "YES" : "NO",
            sig,
            acq > 0 ? "YES" : "NO",
            acq,
            rel,
            proc,
            err,
            proc > 0 ? "YES" : "NO",
            firstWidth,
            firstHeight,
            width, height, format,
            proc,
            proc > 0 ? "YES" : "NO",
            transCount > 0 ? "YES" : "NO",
            transSeq,
            transCount,
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
            WriteDiagnosticStatus("SET_DEVICE_FAILED", 0, 0, 0, 0, 0, 0, 0, 1, 1, hr, 0, 0);
            goto Cleanup;
        }
        OutputDebugStringA("FluxIdd: Worker IddCxSwapChainSetDevice succeeded\n");
        WriteDiagnosticStatus("RUNNING", 0, 0, 0, 0, 0, 0, 0, 0, 1, hr, 0, 0);

        // Open COM1 for host frame transport
        session->hSerialPort = CreateFileA(
            "\\\\.\\COM1",
            GENERIC_WRITE,
            0,
            nullptr,
            OPEN_EXISTING,
            FILE_ATTRIBUTE_NORMAL,
            nullptr
        );
        if (session->hSerialPort != INVALID_HANDLE_VALUE) {
            COMMTIMEOUTS timeouts = {};
            timeouts.WriteTotalTimeoutConstant = 2000;
            SetCommTimeouts(session->hSerialPort, &timeouts);
            OutputDebugStringA("FluxIdd: COM1 transport port opened successfully\n");
        } else {
            DWORD cErr = GetLastError();
            char msg[128];
            sprintf_s(msg, sizeof(msg), "FluxIdd: Failed to open COM1 for transport: %lu\n", cErr);
            OutputDebugStringA(msg);
        }
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
                LONG64 sig = InterlockedIncrement64(&session->surfaceSignalCount);
                if (sig == 1) {
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
                        if (InterlockedCompareExchange(&session->firstFrameWidth, static_cast<LONG>(width), 0) == 0) {
                            InterlockedExchange(&session->firstFrameHeight, static_cast<LONG>(height));
                        }

                        // Staging copy for host transport
                        if (session->d3dDevice) {
                            if (!session->stagingTexture || session->stagingWidth != width || session->stagingHeight != height) {
                                session->stagingTexture.Reset();
                                D3D11_TEXTURE2D_DESC sDesc = desc;
                                sDesc.Usage = D3D11_USAGE_STAGING;
                                sDesc.BindFlags = 0;
                                sDesc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
                                sDesc.MiscFlags = 0;
                                HRESULT sHr = session->d3dDevice->CreateTexture2D(&sDesc, nullptr, &session->stagingTexture);
                                if (SUCCEEDED(sHr)) {
                                    session->stagingWidth = width;
                                    session->stagingHeight = height;
                                }
                            }
                            if (session->stagingTexture) {
                                ComPtr<ID3D11DeviceContext> d3dContext;
                                session->d3dDevice->GetImmediateContext(&d3dContext);
                                d3dContext->CopyResource(session->stagingTexture.Get(), texture.Get());
                            }
                        }
                    }
                }
                // Release the COM reference held by Attach
                dxgiResource.Reset();
            }

            LONG64 rel = InterlockedIncrement64(&session->frameReleaseCount);

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

                // Host Frame Transport transmission (proc <= 5 transmits frames 1..5)
                if (session->stagingTexture && session->hSerialPort != INVALID_HANDLE_VALUE && proc <= 5) {
                    ComPtr<ID3D11DeviceContext> d3dContext;
                    session->d3dDevice->GetImmediateContext(&d3dContext);
                    D3D11_MAPPED_SUBRESOURCE mapped = {};
                    HRESULT mapHr = d3dContext->Map(session->stagingTexture.Get(), 0, D3D11_MAP_READ, 0, &mapped);
                    if (SUCCEEDED(mapHr)) {
                        UINT stride = mapped.RowPitch;
                        UINT dataSize = stride * height;
                        const BYTE* pSrc = static_cast<const BYTE*>(mapped.pData);

                        UINT32 checksum = 0;
                        for (UINT i = 0; i < dataSize; ++i) {
                            checksum += pSrc[i];
                        }

                        UINT32 p0 = (dataSize >= 4) ? *reinterpret_cast<const UINT32*>(pSrc) : 0;
                        UINT centerOff = (height / 2) * stride + (width / 2) * 4;
                        UINT32 pCenter = (centerOff + 4 <= dataSize) ? *reinterpret_cast<const UINT32*>(pSrc + centerOff) : 0;
                        UINT lastOff = (height - 1) * stride + (width - 1) * 4;
                        UINT32 pLast = (lastOff + 4 <= dataSize) ? *reinterpret_cast<const UINT32*>(pSrc + lastOff) : 0;

                        LONG seq = InterlockedIncrement(&session->transportSequence);

                        FluxFrameTransportHeader hdr = {};
                        hdr.magic[0] = 'F'; hdr.magic[1] = 'L'; hdr.magic[2] = 'X'; hdr.magic[3] = 'F';
                        hdr.magic[4] = 'T'; hdr.magic[5] = 'R'; hdr.magic[6] = 'A'; hdr.magic[7] = 'N';
                        hdr.version = 1;
                        hdr.sequence = static_cast<UINT32>(seq);
                        hdr.width = width;
                        hdr.height = height;
                        hdr.stride = stride;
                        hdr.pixelFormat = format;
                        hdr.dataSize = dataSize;
                        hdr.status = 2; // READY
                        hdr.checksum = checksum;
                        hdr.pixel0 = p0;
                        hdr.pixelCenter = pCenter;
                        hdr.pixelLast = pLast;
                        hdr.reserved = 0;

                        DWORD written = 0;
                        WriteFile(session->hSerialPort, &hdr, sizeof(hdr), &written, nullptr);

                        const DWORD chunkSize = 65536;
                        DWORD offset = 0;
                        while (offset < dataSize) {
                            if (WaitForSingleObject(session->hTerminateEvent, 0) == WAIT_OBJECT_0) {
                                break;
                            }
                            DWORD toWrite = min(chunkSize, dataSize - offset);
                            DWORD chunkWritten = 0;
                            if (!WriteFile(session->hSerialPort, pSrc + offset, toWrite, &chunkWritten, nullptr) || chunkWritten == 0) {
                                break;
                            }
                            offset += chunkWritten;
                        }

                        d3dContext->Unmap(session->stagingTexture.Get(), 0);

                        if (offset == dataSize) {
                            InterlockedIncrement(&session->transportFrameCount);
                            char msg[256];
                            sprintf_s(msg, sizeof(msg),
                                "FluxIdd: FRAME_TRANSPORT_SUCCESS seq=%ld width=%u height=%u size=%u checksum=0x%08X\n",
                                seq, width, height, dataSize, checksum);
                            OutputDebugStringA(msg);
                        }
                    }
                }

                if (proc == 1 || proc == 2 || proc == 10 || (proc % 60 == 0)) {
                    LONG64 err = InterlockedCompareExchange64(&session->frameProcessingErrorCount, 0, 0);
                    LONG64 sig = InterlockedCompareExchange64(&session->surfaceSignalCount, 0, 0);
                    UINT firstW = static_cast<UINT>(InterlockedCompareExchange(&session->firstFrameWidth, 0, 0));
                    UINT firstH = static_cast<UINT>(InterlockedCompareExchange(&session->firstFrameHeight, 0, 0));
                    LONG transSeq = InterlockedCompareExchange(&session->transportSequence, 0, 0);
                    LONG transCount = InterlockedCompareExchange(&session->transportFrameCount, 0, 0);
                    char msg[256];
                    sprintf_s(msg, sizeof(msg),
                        "FluxIdd: FRAME_DELIVERY_SUCCESS width=%u height=%u format=%u acquire=%lld released=%lld processed=%lld errors=%lld\n",
                        width, height, format, acq, rel, proc, err);
                    OutputDebugStringA(msg);
                    WriteDiagnosticStatus("ACTIVE", width, height, format, acq, proc, rel, sig, err, 1, session->setDeviceHr, firstW, firstH, transSeq, transCount);
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
            LONG64 rel = InterlockedCompareExchange64(&session->frameReleaseCount, 0, 0);
            LONG64 sig = InterlockedCompareExchange64(&session->surfaceSignalCount, 0, 0);
            LONG64 err = InterlockedCompareExchange64(&session->frameProcessingErrorCount, 0, 0);
            LONG sdc = InterlockedCompareExchange(&session->setDeviceCalled, 0, 0);
            LONG sdhr = InterlockedCompareExchange(&session->setDeviceHr, 0, 0);
            UINT firstW = static_cast<UINT>(InterlockedCompareExchange(&session->firstFrameWidth, 0, 0));
            UINT firstH = static_cast<UINT>(InterlockedCompareExchange(&session->firstFrameHeight, 0, 0));
            LONG transSeq = InterlockedCompareExchange(&session->transportSequence, 0, 0);
            LONG transCount = InterlockedCompareExchange(&session->transportFrameCount, 0, 0);
            WriteDiagnosticStatus("STOPPED", w, h, f, acq, proc, rel, sig, err, sdc, sdhr, firstW, firstH, transSeq, transCount);

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
