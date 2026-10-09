#if __has_include(<windows.h>)
#include <windows.h>
#include <swdevice.h>
#include <devpkey.h>
#include <setupapi.h>
#include <objbase.h>
#pragma comment(lib, "setupapi.lib")
#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "cfgmgr32.lib")
#pragma comment(lib, "swdevice.lib")
#pragma comment(lib, "user32.lib")
#else
typedef void* HANDLE;
typedef void* HMODULE;
typedef void* HDEVINFO;
typedef unsigned long DWORD;
typedef unsigned long ULONG;
typedef int BOOL;
typedef unsigned char BYTE;
typedef BYTE* PBYTE;
typedef wchar_t WCHAR;
typedef const wchar_t* PCWSTR;
typedef const wchar_t* PCZZWSTR;
typedef void* PVOID;
typedef void VOID;
typedef long HRESULT;
typedef long LONG;
#define TRUE 1
#define FALSE 0

typedef struct _devicemodew {
    WCHAR dmDeviceName[32];
    unsigned short dmSpecVersion;
    unsigned short dmDriverVersion;
    unsigned short dmSize;
    unsigned short dmDriverExtra;
    DWORD dmFields;
    short dmOrientation;
    short dmPaperSize;
    short dmPaperLength;
    short dmPaperWidth;
    short dmScale;
    short dmCopies;
    short dmDefaultSource;
    short dmPrintQuality;
    short dmColor;
    short dmDuplex;
    short dmYResolution;
    short dmTTOption;
    short dmCollate;
    WCHAR dmFormName[32];
    unsigned short dmLogPixels;
    DWORD dmBitsPerPel;
    DWORD dmPelsWidth;
    DWORD dmPelsHeight;
    DWORD dmDisplayFlags;
    DWORD dmDisplayFrequency;
    DWORD dmICMMethod;
    DWORD dmICMIntent;
    DWORD dmMediaType;
    DWORD dmDitherType;
    DWORD dmReserved1;
    DWORD dmReserved2;
    DWORD dmPanningWidth;
    DWORD dmPanningHeight;
} DEVMODEW;
typedef struct _GUID {
    unsigned long  Data1;
    unsigned short Data2;
    unsigned short Data3;
    unsigned char  Data4[8];
} GUID;
typedef const GUID* LPCGUID;
typedef struct _SECURITY_DESCRIPTOR SECURITY_DESCRIPTOR;
#define S_OK ((HRESULT)0L)
#define SUCCEEDED(hr) (((HRESULT)(hr)) >= 0)
#define FAILED(hr) (((HRESULT)(hr)) < 0)
#define E_PENDING ((HRESULT)0x8000000AL)
#define INVALID_HANDLE_VALUE ((HANDLE)(long long)-1)
#define ERROR_SUCCESS 0L
#define ERROR_ALREADY_EXISTS 183L
#define EVENT_MODIFY_STATE 0x0002
#define INFINITE 0xFFFFFFFF
#define ERROR_NO_MORE_ITEMS 259L
#define ERROR_FILE_NOT_FOUND 2L
#define ERROR_INVALID_DATA 13L
#define ERROR_INSUFFICIENT_BUFFER 122L
#define REG_MULTI_SZ 7L
#define DIGCF_ALLCLASSES 0x00000004
#define DIGCF_PRESENT    0x00000002
#define SPDRP_HARDWAREID 0x00000001
#define SPDRP_CLASSGUID  0x00000008
#define DIF_REMOVE       0x00000005
#define FORMAT_MESSAGE_ALLOCATE_BUFFER 0x00000100
#define FORMAT_MESSAGE_FROM_SYSTEM     0x00001000
#define FORMAT_MESSAGE_IGNORE_INSERTS  0x00000200
#define WINAPI __stdcall
#define _In_
#define _In_opt_
#define _Out_
#define UNREFERENCED_PARAMETER(P) (void)(P)

typedef struct _SP_DEVINFO_DATA {
    DWORD cbSize;
    GUID ClassGuid;
    DWORD DevInst;
    unsigned long long Reserved;
} SP_DEVINFO_DATA, *PSP_DEVINFO_DATA;

#define DECLARE_HANDLE(name) struct name##__ { int unused; }; typedef struct name##__ *name
DECLARE_HANDLE(HSWDEVICE);

typedef enum _SW_DEVICE_CAPABILITIES {
    SWDeviceCapabilitiesNone = 0x00000000,
    SWDeviceCapabilitiesRemovable = 0x00000001,
    SWDeviceCapabilitiesSilentInstall = 0x00000002,
    SWDeviceCapabilitiesNoDisplayInUI = 0x00000004,
    SWDeviceCapabilitiesDriverRequired = 0x00000008
} SW_DEVICE_CAPABILITIES;

typedef struct _SW_DEVICE_CREATE_INFO {
    ULONG cbSize;
    PCWSTR pszInstanceId;
    PCZZWSTR pszzHardwareIds;
    PCZZWSTR pszzCompatibleIds;
    const GUID *pContainerId;
    ULONG CapabilityFlags;
    PCWSTR pszDeviceDescription;
    PCWSTR pszDeviceLocation;
    const SECURITY_DESCRIPTOR *pSecurityDescriptor;
} SW_DEVICE_CREATE_INFO, *PSW_DEVICE_CREATE_INFO;

typedef enum _SW_DEVICE_LIFETIME {
    SWDeviceLifetimeHandle = 0,
    SWDeviceLifetimeParentPresent = 1,
    SWDeviceLifetimeMax = 2
} SW_DEVICE_LIFETIME;

typedef VOID (WINAPI *SW_DEVICE_CREATE_CALLBACK)(
    _In_ HSWDEVICE hSwDevice,
    _In_ HRESULT hrCreateResult,
    _In_opt_ PVOID pContext,
    _In_opt_ PCWSTR pszDeviceInstanceId
);

typedef ULONG DEVPROPTYPE;
typedef ULONG DEVPROPID;
typedef GUID DEVPROPGUID;

typedef struct _DEVPROPKEY {
    DEVPROPGUID fmtid;
    DEVPROPID pid;
} DEVPROPKEY;

typedef enum _DEVPROPSTORE {
    DEVPROP_STORE_SYSTEM,
    DEVPROP_STORE_USER
} DEVPROPSTORE;

typedef struct _DEVPROPCOMPKEY {
    DEVPROPKEY Key;
    DEVPROPSTORE Store;
    PCWSTR LocaleName;
} DEVPROPCOMPKEY;

typedef struct _DEVPROPERTY {
    DEVPROPCOMPKEY CompKey;
    DEVPROPTYPE Type;
    ULONG BufferSize;
    PVOID Buffer;
} DEVPROPERTY;

#define DEVPROP_TYPE_STRING 0x00000012
#define DEVPROP_TYPE_GUID   0x0000000d

#define STD_OUTPUT_HANDLE ((DWORD)-11)
#define STD_ERROR_HANDLE ((DWORD)-12)

extern "C" {
    DWORD __stdcall GetLastError(VOID);
    VOID __stdcall ExitProcess(unsigned int uExitCode);
    HANDLE __stdcall GetStdHandle(DWORD nStdHandle);
    BOOL __stdcall WriteFile(HANDLE hFile, const void* lpBuffer, DWORD nNumberOfBytesToWrite, DWORD* lpNumberOfBytesWritten, void* lpOverlapped);
    DWORD __stdcall FormatMessageW(DWORD dwFlags, const void* lpSource, DWORD dwMessageId, DWORD dwLanguageId, wchar_t* lpBuffer, DWORD nSize, void* Arguments);
    VOID* __stdcall LocalFree(VOID* hMem);
    HANDLE __stdcall CreateEventW(void* lpEventAttributes, BOOL bManualReset, BOOL bInitialState, PCWSTR lpName);
    BOOL __stdcall SetEvent(HANDLE hEvent);
    BOOL __stdcall ResetEvent(HANDLE hEvent);
    HANDLE __stdcall OpenEventW(DWORD dwDesiredAccess, BOOL bInheritHandle, PCWSTR lpName);
    HANDLE __stdcall CreateMutexW(void* lpMutexAttributes, BOOL bInitialOwner, PCWSTR lpName);
    BOOL __stdcall ReleaseMutex(HANDLE hMutex);
    DWORD __stdcall WaitForSingleObject(HANDLE hHandle, DWORD dwMilliseconds);
    VOID __stdcall Sleep(DWORD dwMilliseconds);
    BOOL __stdcall CloseHandle(HANDLE hObject);
    HMODULE __stdcall LoadLibraryW(PCWSTR lpLibFileName);
    void* __stdcall GetProcAddress(HMODULE hModule, const char* lpProcName);
    BOOL __stdcall FreeLibrary(HMODULE hLibModule);
    HANDLE __stdcall CreateFileW(PCWSTR lpFileName, DWORD dwDesiredAccess, DWORD dwShareMode, void* lpSecurityAttributes, DWORD dwCreationDisposition, DWORD dwFlagsAndAttributes, HANDLE hTemplateFile);
    BOOL __stdcall ReadFile(HANDLE hFile, void* lpBuffer, DWORD nNumberOfBytesToRead, DWORD* lpNumberOfBytesRead, void* lpOverlapped);
    BOOL __stdcall DeleteFileW(PCWSTR lpFileName);

    HDEVINFO __stdcall SetupDiGetClassDevsW(const GUID* ClassGuid, PCWSTR Enumerator, HANDLE hwndParent, DWORD Flags);
    BOOL __stdcall SetupDiEnumDeviceInfo(HDEVINFO DeviceInfoSet, DWORD MemberIndex, PSP_DEVINFO_DATA DeviceInfoData);
    BOOL __stdcall SetupDiGetDeviceRegistryPropertyW(HDEVINFO DeviceInfoSet, PSP_DEVINFO_DATA DeviceInfoData, DWORD Property, DWORD* PropertyRegDataType, BYTE* PropertyBuffer, DWORD PropertyBufferSize, DWORD* RequiredSize);
    BOOL __stdcall SetupDiDestroyDeviceInfoList(HDEVINFO DeviceInfoSet);
    BOOL __stdcall SetupDiGetDeviceInstanceIdW(HDEVINFO DeviceInfoSet, PSP_DEVINFO_DATA DeviceInfoData, wchar_t* DeviceInstanceId, DWORD DeviceInstanceIdSize, DWORD* RequiredSize);
    BOOL __stdcall SetupDiClassNameFromGuidW(const GUID* ClassGuid, wchar_t* ClassName, DWORD ClassNameSize, DWORD* RequiredSize);
    HDEVINFO __stdcall SetupDiCreateDeviceInfoList(const GUID* ClassGuid, HANDLE hwndParent);
    BOOL __stdcall SetupDiOpenDeviceInfoW(HDEVINFO DeviceInfoSet, PCWSTR DeviceInstanceId, HANDLE hwndParent, DWORD OpenFlags, PSP_DEVINFO_DATA DeviceInfoData);
    BOOL __stdcall SetupDiCallClassInstaller(DWORD InstallFunction, HDEVINFO DeviceInfoSet, PSP_DEVINFO_DATA DeviceInfoData);

    int __stdcall StringFromGUID2(const GUID& rguid, wchar_t* lpsz, int cchMax);
    HRESULT __stdcall CLSIDFromString(PCWSTR lpsz, GUID* pclsid);
    wchar_t** __stdcall CommandLineToArgvW(PCWSTR lpCmdLine, int* pNumArgs);
    PCWSTR __stdcall GetCommandLineW(VOID);
}
#endif

#if !defined(_MSC_VER) || defined(__clang__)
extern "C" {
    void* memset(void* dest, int c, unsigned long long count) {
        unsigned char* p = (unsigned char*)dest;
        while (count--) *p++ = (unsigned char)c;
        return dest;
    }
    void* memcpy(void* dest, const void* src, unsigned long long count) {
        unsigned char* d = (unsigned char*)dest;
        const unsigned char* s = (const unsigned char*)src;
        while (count--) *d++ = *s++;
        return dest;
    }
    void __chkstk() {}
}
#endif

// Dynamic function pointers for SwDevice APIs
typedef HRESULT (WINAPI *PFN_SwDeviceCreate)(
    PCWSTR pszEnumeratorName,
    PCWSTR pszParentDeviceInstance,
    const SW_DEVICE_CREATE_INFO *pCreateInfo,
    ULONG cPropertyCount,
    const DEVPROPERTY *pProperties,
    SW_DEVICE_CREATE_CALLBACK pCallback,
    PVOID pContext,
    HSWDEVICE *phSwDevice
);

typedef VOID (WINAPI *PFN_SwDeviceClose)(
    HSWDEVICE hSwDevice
);

typedef HRESULT (WINAPI *PFN_SwDeviceSetLifetime)(
    HSWDEVICE hSwDevice,
    SW_DEVICE_LIFETIME Lifetime
);

namespace {

static const DEVPROPKEY kDEVPKEY_Device_FriendlyName = {
    { 0xa45c254e, 0xdf1c, 0x4efd, { 0x80, 0x20, 0x67, 0xd1, 0x46, 0xa8, 0x50, 0xe0 } }, 14
};

static const DEVPROPKEY kDEVPKEY_Device_Manufacturer = {
    { 0xa45c254e, 0xdf1c, 0x4efd, { 0x80, 0x20, 0x67, 0xd1, 0x46, 0xa8, 0x50, 0xe0 } }, 13
};

static const DEVPROPKEY kDEVPKEY_Device_Class = {
    { 0xa45c254e, 0xdf1c, 0x4efd, { 0x80, 0x20, 0x67, 0xd1, 0x46, 0xa8, 0x50, 0xe0 } }, 9
};

static const DEVPROPKEY kDEVPKEY_Device_ClassGuid = {
    { 0xa45c254e, 0xdf1c, 0x4efd, { 0x80, 0x20, 0x67, 0xd1, 0x46, 0xa8, 0x50, 0xe0 } }, 10
};

// Console output helpers
void PrintStr(HANDLE h, const wchar_t* s) {
    if (!s) return;
    unsigned long len = 0;
    while (s[len]) len++;
    DWORD written = 0;
    char buf[1024];
    unsigned long bi = 0;
    for (unsigned long i = 0; i < len; i++) {
        wchar_t c = s[i];
        if (c < 0x80) {
            buf[bi++] = (char)c;
        } else if (c < 0x800) {
            buf[bi++] = (char)(0xC0 | (c >> 6));
            buf[bi++] = (char)(0x80 | (c & 0x3F));
        } else {
            buf[bi++] = (char)(0xE0 | (c >> 12));
            buf[bi++] = (char)(0x80 | ((c >> 6) & 0x3F));
            buf[bi++] = (char)(0x80 | (c & 0x3F));
        }
        if (bi >= sizeof(buf) - 4) {
            WriteFile(h, buf, bi, &written, 0);
            bi = 0;
        }
    }
    if (bi > 0) {
        WriteFile(h, buf, bi, &written, 0);
    }
}

void Out(const wchar_t* s) {
    PrintStr(GetStdHandle(STD_OUTPUT_HANDLE), s);
}

void OutLine(const wchar_t* s) {
    HANDLE h = GetStdHandle(STD_OUTPUT_HANDLE);
    PrintStr(h, s);
    PrintStr(h, L"\r\n");
}

void Err(const wchar_t* s) {
    PrintStr(GetStdHandle(STD_ERROR_HANDLE), s);
}

void ErrLine(const wchar_t* s) {
    HANDLE h = GetStdHandle(STD_ERROR_HANDLE);
    PrintStr(h, s);
    PrintStr(h, L"\r\n");
}

void OutHex(const wchar_t* prefix, DWORD val) {
    wchar_t buf[64];
    unsigned long pos = 0;
    while (prefix[pos]) { buf[pos] = prefix[pos]; pos++; }
    buf[pos++] = L'0'; buf[pos++] = L'x';
    for (int i = 7; i >= 0; i--) {
        unsigned int nib = (val >> (i * 4)) & 0xF;
        buf[pos++] = static_cast<wchar_t>((nib < 10) ? (L'0' + nib) : (L'A' + nib - 10));
    }
    buf[pos++] = L'\r'; buf[pos++] = L'\n'; buf[pos] = L'\0';
    Out(buf);
}

void OutDec(const wchar_t* prefix, DWORD val) {
    wchar_t buf[64];
    unsigned long pos = 0;
    while (prefix[pos]) { buf[pos] = prefix[pos]; pos++; }
    wchar_t num[16];
    int ni = 0;
    if (val == 0) num[ni++] = L'0';
    else {
        DWORD t = val;
        while (t > 0) { num[ni++] = static_cast<wchar_t>(L'0' + (t % 10)); t /= 10; }
    }
    for (int i = ni - 1; i >= 0; i--) buf[pos++] = num[i];
    buf[pos++] = L'\r'; buf[pos++] = L'\n'; buf[pos] = L'\0';
    Out(buf);
}

int StrICmp(const wchar_t* s1, const wchar_t* s2) {
    while (*s1 && *s2) {
        wchar_t c1 = *s1;
        wchar_t c2 = *s2;
        if (c1 >= L'A' && c1 <= L'Z') c1 = static_cast<wchar_t>(c1 + (L'a' - L'A'));
        if (c2 >= L'A' && c2 <= L'Z') c2 = static_cast<wchar_t>(c2 + (L'a' - L'A'));
        if (c1 != c2) return (int)(c1 - c2);
        s1++; s2++;
    }
    return (int)(*s1 - *s2);
}

unsigned long StrLen(const wchar_t* s) {
    unsigned long l = 0;
    while (s[l]) l++;
    return l;
}

bool StrStartsWith(const wchar_t* str, const wchar_t* prefix) {
    while (*prefix) {
        wchar_t c1 = *str++;
        wchar_t c2 = *prefix++;
        if (c1 >= L'A' && c1 <= L'Z') c1 += (L'a' - L'A');
        if (c2 >= L'A' && c2 <= L'Z') c2 += (L'a' - L'A');
        if (c1 != c2) return false;
    }
    return true;
}

DWORD ParseDec(const wchar_t* s) {
    if (!s) return 0;
    DWORD val = 0;
    while (*s >= L'0' && *s <= L'9') {
        val = val * 10 + (*s - L'0');
        s++;
    }
    return val;
}

void PrintWin32Failure(const wchar_t* api, DWORD error) {
    wchar_t* message = nullptr;
    const DWORD flags = FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM |
                        FORMAT_MESSAGE_IGNORE_INSERTS;
    FormatMessageW(flags, nullptr, error, 0, reinterpret_cast<wchar_t*>(&message), 0, nullptr);
    Err(api); Err(L" FAILED GetLastError=");
    wchar_t errBuf[32];
    int ei = 0;
    DWORD temp = error;
    if (temp == 0) errBuf[ei++] = L'0';
    else {
        while (temp > 0) { errBuf[ei++] = L'0' + (temp % 10); temp /= 10; }
    }
    for (int i = 0; i < ei / 2; i++) { wchar_t tc = errBuf[i]; errBuf[i] = errBuf[ei-1-i]; errBuf[ei-1-i] = tc; }
    errBuf[ei] = L'\0';
    Err(errBuf);
    if (message != nullptr) {
        Err(L" MESSAGE="); Err(message);
        LocalFree(message);
    }
    ErrLine(L"");
}

bool ContainsHardwareId(const BYTE* data, DWORD byteCount, const wchar_t* wanted) {
    if (data == nullptr || byteCount < sizeof(wchar_t)) return false;
    const wchar_t* current = reinterpret_cast<const wchar_t*>(data);
    const wchar_t* end = reinterpret_cast<const wchar_t*>(data + byteCount);
    while (current < end && *current != L'\0') {
        if (StrICmp(current, wanted) == 0) return true;
        current += StrLen(current) + 1;
    }
    return false;
}

struct DeviceMatch {
    wchar_t instanceId[512];
    bool isSwd;
    bool isRoot;
};

bool EnumerateMatchingDevices(const wchar_t* wantedHardwareId, DeviceMatch* matches, DWORD maxMatches, DWORD* outCount) {
    *outCount = 0;
    HDEVINFO set = SetupDiGetClassDevsW(nullptr, nullptr, nullptr, DIGCF_ALLCLASSES | DIGCF_PRESENT);
    if (set == INVALID_HANDLE_VALUE) {
        PrintWin32Failure(L"SetupDiGetClassDevs", GetLastError());
        return false;
    }

    for (DWORD idx = 0;; ++idx) {
        SP_DEVINFO_DATA d{};
        d.cbSize = sizeof(d);
        if (!SetupDiEnumDeviceInfo(set, idx, &d)) {
            DWORD err = GetLastError();
            if (err == ERROR_NO_MORE_ITEMS) break;
            PrintWin32Failure(L"SetupDiEnumDeviceInfo", err);
            SetupDiDestroyDeviceInfoList(set);
            return false;
        }

        DWORD propType = 0, reqBytes = 0;
        if (!SetupDiGetDeviceRegistryPropertyW(set, &d, SPDRP_HARDWAREID, &propType, nullptr, 0, &reqBytes)) {
            DWORD err = GetLastError();
            if (err == ERROR_INVALID_DATA || err == ERROR_FILE_NOT_FOUND) continue;
            if (err != ERROR_INSUFFICIENT_BUFFER) continue;
        }

        if (propType != REG_MULTI_SZ || reqBytes == 0) continue;

        BYTE hwBuf[1024];
        if (reqBytes > sizeof(hwBuf)) continue;
        if (!SetupDiGetDeviceRegistryPropertyW(set, &d, SPDRP_HARDWAREID, &propType, hwBuf, reqBytes, nullptr)) continue;

        if (ContainsHardwareId(hwBuf, reqBytes, wantedHardwareId)) {
            if (*outCount < maxMatches) {
                DeviceMatch& m = matches[*outCount];
                m.instanceId[0] = L'\0';
                SetupDiGetDeviceInstanceIdW(set, &d, m.instanceId, 512, nullptr);
                m.isSwd = StrStartsWith(m.instanceId, L"SWD\\");
                m.isRoot = StrStartsWith(m.instanceId, L"ROOT\\");
            }
            (*outCount)++;
        }
    }

    SetupDiDestroyDeviceInfoList(set);
    return true;
}

bool CountHardwareIds(const wchar_t* hardwareId, DWORD* count) {
    DeviceMatch matches[16];
    return EnumerateMatchingDevices(hardwareId, matches, 16, count);
}

bool QueryHardwareId(const wchar_t* hardwareId) {
    HDEVINFO set = SetupDiGetClassDevsW(nullptr, nullptr, nullptr, DIGCF_ALLCLASSES);
    if (set == INVALID_HANDLE_VALUE) {
        PrintWin32Failure(L"SetupDiGetClassDevs(query)", GetLastError());
        return false;
    }
    DWORD matches = 0;
    for (DWORD i = 0;; ++i) {
        SP_DEVINFO_DATA d{};
        d.cbSize = sizeof(d);
        if (!SetupDiEnumDeviceInfo(set, i, &d)) {
            if (GetLastError() == ERROR_NO_MORE_ITEMS) break;
            SetupDiDestroyDeviceInfoList(set);
            return false;
        }
        DWORD type = 0, bytes = 0;
        SetupDiGetDeviceRegistryPropertyW(set, &d, SPDRP_HARDWAREID, &type, nullptr, 0, &bytes);
        if (bytes == 0) continue;
        BYTE hwBuf[1024];
        if (bytes > sizeof(hwBuf)) continue;
        if (!SetupDiGetDeviceRegistryPropertyW(set, &d, SPDRP_HARDWAREID, &type, hwBuf, bytes, nullptr) ||
            type != REG_MULTI_SZ) continue;
        if (!ContainsHardwareId(hwBuf, bytes, hardwareId)) continue;
        matches++;

        wchar_t instId[512] = {};
        if (SetupDiGetDeviceInstanceIdW(set, &d, instId, 512, nullptr)) {
            Out(L"INSTANCE_ID="); OutLine(instId);
            Out(L"IS_SWD="); OutLine(StrStartsWith(instId, L"SWD\\") ? L"YES" : L"NO");
            Out(L"IS_ROOT="); OutLine(StrStartsWith(instId, L"ROOT\\") ? L"YES" : L"NO");
        }
        Out(L"HARDWARE_ID="); OutLine(hardwareId);

        wchar_t g[64] = {};
        StringFromGUID2(d.ClassGuid, g, 64);
        Out(L"CLASS_GUID="); OutLine(g);

        wchar_t cname[256] = {};
        if (SetupDiClassNameFromGuidW(&d.ClassGuid, cname, 256, nullptr)) {
            Out(L"CLASS_NAME="); OutLine(cname);
        }
        wchar_t prop[128] = {};
        DWORD pt = 0;
        if (SetupDiGetDeviceRegistryPropertyW(set, &d, SPDRP_CLASSGUID, &pt,
                                              reinterpret_cast<PBYTE>(prop), sizeof(prop) - sizeof(wchar_t), nullptr)) {
            Out(L"SPDRP_CLASSGUID="); OutLine(prop);
        }
    }
    OutDec(L"MATCH_COUNT=", matches);
    SetupDiDestroyDeviceInfoList(set);
    return true;
}

struct SwCreationContext {
    HANDLE hEvent;
    HRESULT hrResult;
    wchar_t instanceId[512];
};

VOID WINAPI SwDeviceCreationCallback(
    HSWDEVICE hSwDevice,
    HRESULT hrCreateResult,
    PVOID pContext,
    PCWSTR pszDeviceInstanceId
) {
    UNREFERENCED_PARAMETER(hSwDevice);
    auto* ctx = reinterpret_cast<SwCreationContext*>(pContext);
    if (ctx) {
        ctx->hrResult = hrCreateResult;
        if (pszDeviceInstanceId) {
            unsigned long len = StrLen(pszDeviceInstanceId);
            if (len >= 512) len = 511;
            for (unsigned long i = 0; i < len; i++) ctx->instanceId[i] = pszDeviceInstanceId[i];
            ctx->instanceId[len] = L'\0';
        }
        SetEvent(ctx->hEvent);
    }
}

bool RemoveDeviceInstance(const wchar_t* instanceId);

bool CreateSoftwareDevice(const wchar_t* wantedHardwareId, const GUID& classGuid) {
    (void)classGuid;
    // 1. Guardrail duplicate check
    DeviceMatch existing[16];
    DWORD existingCount = 0;
    if (!EnumerateMatchingDevices(wantedHardwareId, existing, 16, &existingCount)) {
        OutLine(L"RESULT=FAIL_ENUM_CHECK");
        return false;
    }

    if (existingCount > 0) {
        OutLine(L"ALREADY_EXISTS=YES");
        bool hasSwd = false;
        bool hasRoot = false;
        for (DWORD i = 0; i < existingCount && i < 16; i++) {
            Out(L"EXISTING_INSTANCE_ID="); OutLine(existing[i].instanceId);
            Out(L"EXISTING_IS_SWD="); OutLine(existing[i].isSwd ? L"YES" : L"NO");
            Out(L"EXISTING_IS_ROOT="); OutLine(existing[i].isRoot ? L"YES" : L"NO");
            if (existing[i].isSwd) hasSwd = true;
            if (existing[i].isRoot) hasRoot = true;
        }
        if (hasSwd) {
            OutLine(L"RESULT=STOP_ALREADY_EXISTS");
            return true;
        }
        if (hasRoot) {
            OutLine(L"RESULT=BLOCKED_LEGACY_EXISTS");
            ErrLine(L"A legacy ROOT device exists. Remove ROOT device before creating SWD device.");
            return false;
        }
    }
    OutLine(L"ALREADY_EXISTS=NO");

    // 2. Resolve SwDevice and ConfigMgr APIs (cfgmgr32.dll with swdevice.dll fallback)
    HMODULE hCfgMgr = LoadLibraryW(L"cfgmgr32.dll");
    if (!hCfgMgr) hCfgMgr = LoadLibraryW(L"swdevice.dll");
    if (!hCfgMgr) {
        PrintWin32Failure(L"LoadLibrary(cfgmgr32.dll)", GetLastError());
        OutLine(L"RESULT=FAIL_LOAD_CFGMGR32");
        return false;
    }

    auto pfnSwDeviceCreate = reinterpret_cast<PFN_SwDeviceCreate>(GetProcAddress(hCfgMgr, "SwDeviceCreate"));
    auto pfnSwDeviceClose = reinterpret_cast<PFN_SwDeviceClose>(GetProcAddress(hCfgMgr, "SwDeviceClose"));
    auto pfnSwDeviceSetLifetime = reinterpret_cast<PFN_SwDeviceSetLifetime>(GetProcAddress(hCfgMgr, "SwDeviceSetLifetime"));

    if (!pfnSwDeviceCreate || !pfnSwDeviceClose || !pfnSwDeviceSetLifetime) {
        ErrLine(L"SwDevice APIs not exported by cfgmgr32/swdevice.");
        FreeLibrary(hCfgMgr);
        OutLine(L"RESULT=FAIL_RESOLVE_APIS");
        return false;
    }

    // Resolve root parent device instance (HTREE\ROOT\0)
    typedef DWORD CONFIGRET;
    typedef DWORD DEVINST;
    typedef CONFIGRET (WINAPI *PFN_CM_Locate_DevNodeW)(DEVINST* pdnDevInst, PCWSTR pDeviceID, ULONG ulFlags);
    typedef CONFIGRET (WINAPI *PFN_CM_Get_Device_IDW)(DEVINST dnDevInst, wchar_t* Buffer, ULONG BufferLen, ULONG ulFlags);

    wchar_t rootNodeName[256] = L"HTREE\\ROOT\\0";
    auto pfnCM_Locate_DevNodeW = reinterpret_cast<PFN_CM_Locate_DevNodeW>(GetProcAddress(hCfgMgr, "CM_Locate_DevNodeW"));
    auto pfnCM_Get_Device_IDW = reinterpret_cast<PFN_CM_Get_Device_IDW>(GetProcAddress(hCfgMgr, "CM_Get_Device_IDW"));
    if (pfnCM_Locate_DevNodeW && pfnCM_Get_Device_IDW) {
        DEVINST rootDevInst = 0;
        if (pfnCM_Locate_DevNodeW(&rootDevInst, nullptr, 0) == 0) {
            wchar_t buf[256] = {};
            if (pfnCM_Get_Device_IDW(rootDevInst, buf, 256, 0) == 0 && buf[0] != L'\0') {
                unsigned long blen = StrLen(buf);
                if (blen < 256) {
                    for (unsigned long bi = 0; bi <= blen; bi++) rootNodeName[bi] = buf[bi];
                }
            }
        }
    }
    Out(L"PARENT_DEVICE_INSTANCE="); OutLine(rootNodeName);

    // 3. Prepare Multi-Sz Hardware IDs and Compatible IDs
    // Primary match: ROOT\FLUX_IDD (matches oem2.inf)
    // Secondary match: FluxIdd
    wchar_t hwIds[256];
    unsigned long hwi = 0;
    unsigned long whLen = StrLen(wantedHardwareId);
    for (unsigned long i = 0; i < whLen; i++) hwIds[hwi++] = wantedHardwareId[i];
    hwIds[hwi++] = L'\0';
    const wchar_t secHwId[] = L"FluxIdd";
    for (unsigned long i = 0; i < StrLen(secHwId); i++) hwIds[hwi++] = secHwId[i];
    hwIds[hwi++] = L'\0';
    hwIds[hwi++] = L'\0'; // Double null

    const wchar_t compIds[] = L"FluxIdd\0";
    const wchar_t devDesc[] = L"Flux Virtual Display Adapter";

    SW_DEVICE_CREATE_INFO createInfo = {};
    createInfo.cbSize = sizeof(createInfo);
    createInfo.pszInstanceId = L"0";
    createInfo.pszzHardwareIds = hwIds;
    createInfo.pszzCompatibleIds = compIds;
    createInfo.pContainerId = nullptr;
    createInfo.CapabilityFlags = SWDeviceCapabilitiesRemovable | SWDeviceCapabilitiesSilentInstall | SWDeviceCapabilitiesDriverRequired;
    createInfo.pszDeviceDescription = devDesc;
    createInfo.pszDeviceLocation = nullptr;
    createInfo.pSecurityDescriptor = nullptr;

    // 4. Async synchronization setup
    SwCreationContext ctx = {};
    ctx.hEvent = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    ctx.hrResult = E_PENDING;
    ctx.instanceId[0] = L'\0';

    if (!ctx.hEvent) {
        PrintWin32Failure(L"CreateEventW", GetLastError());
        FreeLibrary(hCfgMgr);
        OutLine(L"RESULT=FAIL_CREATE_EVENT");
        return false;
    }

    HSWDEVICE hSwDevice = nullptr;
    HRESULT hr = pfnSwDeviceCreate(
        L"FluxIdd",
        rootNodeName,
        &createInfo,
        0,
        nullptr,
        SwDeviceCreationCallback,
        &ctx,
        &hSwDevice
    );

    if (hr == (HRESULT)0x800700B7L) {
        OutLine(L"SWD_EXISTS_CLEANING_OLD=YES");
        RemoveDeviceInstance(L"SWD\\FluxIdd\\0");
        Sleep(1000);
        ctx.hrResult = E_PENDING;
        ResetEvent(ctx.hEvent);
        hr = pfnSwDeviceCreate(
            L"FluxIdd",
            rootNodeName,
            &createInfo,
            0,
            nullptr,
            SwDeviceCreationCallback,
            &ctx,
            &hSwDevice
        );
    }

    if (FAILED(hr)) {
        OutHex(L"SWDEVICE_CREATE_HRESULT=", (DWORD)hr);
        CloseHandle(ctx.hEvent);
        FreeLibrary(hCfgMgr);
        OutLine(L"RESULT=FAIL_SWDEVICE_CREATE");
        return false;
    }
    OutLine(L"SWDEVICE_CREATE_CALL=PASS");

    // 5. Wait for creation callback (15 seconds timeout)
    DWORD waitRes = WaitForSingleObject(ctx.hEvent, 15000);
    CloseHandle(ctx.hEvent);

    if (waitRes != 0) { // not WAIT_OBJECT_0
        OutLine(L"SWD_CREATION=TIMEOUT");
        pfnSwDeviceClose(hSwDevice);
        FreeLibrary(hCfgMgr);
        OutLine(L"RESULT=FAIL_TIMEOUT");
        return false;
    }

    if (FAILED(ctx.hrResult)) {
        OutHex(L"SWD_CREATION_CALLBACK_HRESULT=", (DWORD)ctx.hrResult);
        OutLine(L"SWD_CREATION=FAIL");
        pfnSwDeviceClose(hSwDevice);
        FreeLibrary(hCfgMgr);
        OutLine(L"RESULT=FAIL_CALLBACK");
        return false;
    }

    OutLine(L"SWD_CREATION=PASS");
    Out(L"SWD_INSTANCE_ID="); OutLine(ctx.instanceId);

    // 7. Establish Persistent Lifetime (SWDeviceLifetimeParentPresent)
    HRESULT hrLifetime = pfnSwDeviceSetLifetime(hSwDevice, SWDeviceLifetimeParentPresent);
    if (SUCCEEDED(hrLifetime)) {
        OutLine(L"SWDEVICE_LIFETIME_MODEL=SwDeviceLifetimeParentPresent");
        OutLine(L"PERSISTENT_ACROSS_PROCESS_EXIT=YES");
    } else {
        OutHex(L"SWDEVICE_LIFETIME_SET_FAIL_HRESULT=", (DWORD)hrLifetime);
    }

    // 8. Close creator handle cleanly
    pfnSwDeviceClose(hSwDevice);
    OutLine(L"SWD_HANDLE_CLOSED=YES");
    FreeLibrary(hCfgMgr);

    OutLine(L"RESULT=SUCCESS");
    return true;
}

bool RemoveDeviceInstance(const wchar_t* instanceId) {
    HDEVINFO set = SetupDiCreateDeviceInfoList(nullptr, nullptr);
    if (set == INVALID_HANDLE_VALUE) {
        PrintWin32Failure(L"SetupDiCreateDeviceInfoList(remove)", GetLastError());
        return false;
    }
    SP_DEVINFO_DATA d{};
    d.cbSize = sizeof(d);
    if (!SetupDiOpenDeviceInfoW(set, instanceId, nullptr, 0, &d)) {
        PrintWin32Failure(L"SetupDiOpenDeviceInfo", GetLastError());
        SetupDiDestroyDeviceInfoList(set);
        return false;
    }
    if (!SetupDiCallClassInstaller(DIF_REMOVE, set, &d)) {
        PrintWin32Failure(L"SetupDiCallClassInstaller(DIF_REMOVE)", GetLastError());
        SetupDiDestroyDeviceInfoList(set);
        return false;
    }
    SetupDiDestroyDeviceInfoList(set);
    Out(L"REMOVED_INSTANCE="); OutLine(instanceId);
    OutLine(L"RESULT=SUCCESS");
    return true;
}

bool RunDaemon(const wchar_t* wantedHardwareId, const GUID& classGuid, DWORD durationSeconds) {
    (void)classGuid;
    // 1. Single-instance mutex
    HANDLE hMutex = CreateMutexW(nullptr, FALSE, L"Local\\FluxDevNodeDaemonMutex");
    if (!hMutex) {
        PrintWin32Failure(L"CreateMutexW", GetLastError());
        OutLine(L"RESULT=FAIL_MUTEX");
        return false;
    }
    if (GetLastError() == ERROR_ALREADY_EXISTS) {
        OutLine(L"DAEMON_ALREADY_RUNNING=YES");
        OutLine(L"RESULT=STOP_ALREADY_RUNNING");
        CloseHandle(hMutex);
        return true;
    }

    // 2. Stop event
    HANDLE hStopEvent = CreateEventW(nullptr, TRUE, FALSE, L"Local\\FluxDevNodeStopEvent");
    if (!hStopEvent) {
        PrintWin32Failure(L"CreateEventW(stop)", GetLastError());
        CloseHandle(hMutex);
        OutLine(L"RESULT=FAIL_STOP_EVENT");
        return false;
    }
    ResetEvent(hStopEvent);

    // 3. Guardrail check for legacy ROOT devices
    DeviceMatch existing[16];
    DWORD existingCount = 0;
    if (!EnumerateMatchingDevices(wantedHardwareId, existing, 16, &existingCount)) {
        OutLine(L"RESULT=FAIL_ENUM_CHECK");
        CloseHandle(hStopEvent);
        CloseHandle(hMutex);
        return false;
    }

    if (existingCount > 0) {
        OutLine(L"EXISTING_DEVICES_DETECTED=YES");
        bool hasRoot = false;
        for (DWORD i = 0; i < existingCount && i < 16; i++) {
            Out(L"EXISTING_INSTANCE_ID="); OutLine(existing[i].instanceId);
            Out(L"EXISTING_IS_SWD="); OutLine(existing[i].isSwd ? L"YES" : L"NO");
            Out(L"EXISTING_IS_ROOT="); OutLine(existing[i].isRoot ? L"YES" : L"NO");
            if (existing[i].isRoot) hasRoot = true;
        }
        if (hasRoot) {
            OutLine(L"RESULT=BLOCKED_LEGACY_EXISTS");
            ErrLine(L"A legacy ROOT device exists. Remove ROOT device before starting daemon.");
            CloseHandle(hStopEvent);
            CloseHandle(hMutex);
            return false;
        }
    }

    // 4. Resolve SwDevice APIs
    HMODULE hCfgMgr = LoadLibraryW(L"cfgmgr32.dll");
    if (!hCfgMgr) hCfgMgr = LoadLibraryW(L"swdevice.dll");
    if (!hCfgMgr) {
        PrintWin32Failure(L"LoadLibrary(cfgmgr32.dll)", GetLastError());
        CloseHandle(hStopEvent);
        CloseHandle(hMutex);
        OutLine(L"RESULT=FAIL_LOAD_CFGMGR32");
        return false;
    }

    auto pfnSwDeviceCreate = reinterpret_cast<PFN_SwDeviceCreate>(GetProcAddress(hCfgMgr, "SwDeviceCreate"));
    auto pfnSwDeviceClose = reinterpret_cast<PFN_SwDeviceClose>(GetProcAddress(hCfgMgr, "SwDeviceClose"));

    if (!pfnSwDeviceCreate || !pfnSwDeviceClose) {
        ErrLine(L"SwDevice APIs not exported by cfgmgr32/swdevice.");
        FreeLibrary(hCfgMgr);
        CloseHandle(hStopEvent);
        CloseHandle(hMutex);
        OutLine(L"RESULT=FAIL_RESOLVE_APIS");
        return false;
    }

    // Resolve root parent device instance (HTREE\ROOT\0)
    typedef DWORD CONFIGRET;
    typedef DWORD DEVINST;
    typedef CONFIGRET (WINAPI *PFN_CM_Locate_DevNodeW)(DEVINST* pdnDevInst, PCWSTR pDeviceID, ULONG ulFlags);
    typedef CONFIGRET (WINAPI *PFN_CM_Get_Device_IDW)(DEVINST dnDevInst, wchar_t* Buffer, ULONG BufferLen, ULONG ulFlags);

    wchar_t rootNodeName[256] = L"HTREE\\ROOT\\0";
    auto pfnCM_Locate_DevNodeW = reinterpret_cast<PFN_CM_Locate_DevNodeW>(GetProcAddress(hCfgMgr, "CM_Locate_DevNodeW"));
    auto pfnCM_Get_Device_IDW = reinterpret_cast<PFN_CM_Get_Device_IDW>(GetProcAddress(hCfgMgr, "CM_Get_Device_IDW"));
    if (pfnCM_Locate_DevNodeW && pfnCM_Get_Device_IDW) {
        DEVINST rootDevInst = 0;
        if (pfnCM_Locate_DevNodeW(&rootDevInst, nullptr, 0) == 0) {
            wchar_t buf[256] = {};
            if (pfnCM_Get_Device_IDW(rootDevInst, buf, 256, 0) == 0 && buf[0] != L'\0') {
                unsigned long blen = StrLen(buf);
                if (blen < 256) {
                    for (unsigned long bi = 0; bi <= blen; bi++) rootNodeName[bi] = buf[bi];
                }
            }
        }
    }
    Out(L"PARENT_DEVICE_INSTANCE="); OutLine(rootNodeName);

    // 5. Prepare hardware IDs
    wchar_t hwIds[256];
    unsigned long hwi = 0;
    unsigned long whLen = StrLen(wantedHardwareId);
    for (unsigned long i = 0; i < whLen; i++) hwIds[hwi++] = wantedHardwareId[i];
    hwIds[hwi++] = L'\0';
    const wchar_t secHwId[] = L"FluxIdd";
    for (unsigned long i = 0; i < StrLen(secHwId); i++) hwIds[hwi++] = secHwId[i];
    hwIds[hwi++] = L'\0';
    hwIds[hwi++] = L'\0';

    const wchar_t compIds[] = L"FluxIdd\0";
    const wchar_t devDesc[] = L"Flux Virtual Display Adapter";

    SW_DEVICE_CREATE_INFO createInfo = {};
    createInfo.cbSize = sizeof(createInfo);
    createInfo.pszInstanceId = L"0";
    createInfo.pszzHardwareIds = hwIds;
    createInfo.pszzCompatibleIds = compIds;
    createInfo.pContainerId = nullptr;
    createInfo.CapabilityFlags = SWDeviceCapabilitiesRemovable | SWDeviceCapabilitiesSilentInstall | SWDeviceCapabilitiesDriverRequired;
    createInfo.pszDeviceDescription = devDesc;
    createInfo.pszDeviceLocation = nullptr;
    createInfo.pSecurityDescriptor = nullptr;

    SwCreationContext ctx = {};
    ctx.hEvent = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    ctx.hrResult = E_PENDING;
    ctx.instanceId[0] = L'\0';

    if (!ctx.hEvent) {
        PrintWin32Failure(L"CreateEventW", GetLastError());
        FreeLibrary(hCfgMgr);
        CloseHandle(hStopEvent);
        CloseHandle(hMutex);
        OutLine(L"RESULT=FAIL_CREATE_EVENT");
        return false;
    }

    HSWDEVICE hSwDevice = nullptr;
    HRESULT hr = pfnSwDeviceCreate(
        L"FluxIdd",
        rootNodeName,
        &createInfo,
        0,
        nullptr,
        SwDeviceCreationCallback,
        &ctx,
        &hSwDevice
    );

    if (hr == (HRESULT)0x800700B7L) {
        OutLine(L"SWD_EXISTS_CLEANING_OLD=YES");
        RemoveDeviceInstance(L"SWD\\FluxIdd\\0");
        Sleep(1000);
        ctx.hrResult = E_PENDING;
        ResetEvent(ctx.hEvent);
        hr = pfnSwDeviceCreate(
            L"FluxIdd",
            rootNodeName,
            &createInfo,
            0,
            nullptr,
            SwDeviceCreationCallback,
            &ctx,
            &hSwDevice
        );
    }

    if (FAILED(hr)) {
        OutHex(L"SWDEVICE_CREATE_HRESULT=", (DWORD)hr);
        CloseHandle(ctx.hEvent);
        CloseHandle(hStopEvent);
        CloseHandle(hMutex);
        FreeLibrary(hCfgMgr);
        OutLine(L"RESULT=FAIL_SWDEVICE_CREATE");
        return false;
    }
    OutLine(L"SWDEVICE_CREATE_CALL=PASS");

    // 6. Wait for creation callback (15s timeout)
    DWORD waitRes = WaitForSingleObject(ctx.hEvent, 15000);
    CloseHandle(ctx.hEvent);

    if (waitRes != 0) {
        OutLine(L"SWD_CREATION=TIMEOUT");
        pfnSwDeviceClose(hSwDevice);
        CloseHandle(hStopEvent);
        CloseHandle(hMutex);
        FreeLibrary(hCfgMgr);
        OutLine(L"RESULT=FAIL_TIMEOUT");
        return false;
    }

    if (FAILED(ctx.hrResult)) {
        OutHex(L"SWD_CREATION_CALLBACK_HRESULT=", (DWORD)ctx.hrResult);
        OutLine(L"SWD_CREATION=FAIL");
        pfnSwDeviceClose(hSwDevice);
        CloseHandle(hStopEvent);
        CloseHandle(hMutex);
        FreeLibrary(hCfgMgr);
        OutLine(L"RESULT=FAIL_CALLBACK");
        return false;
    }

    OutLine(L"SWD_CREATION=PASS");
    Out(L"SWD_INSTANCE_ID="); OutLine(ctx.instanceId);
    OutLine(L"DAEMON_STATUS=RUNNING");
    OutLine(L"HOLDING_HANDLE=YES");

    // 7. Daemon wait loop: hold handle open until stop event or timeout
    DWORD maxWaitMs = (durationSeconds > 0) ? (durationSeconds * 1000) : INFINITE;
    DWORD elapsedMs = 0;
    while (true) {
        DWORD waitChunk = 5000;
        if (maxWaitMs != INFINITE) {
            if (elapsedMs >= maxWaitMs) {
                OutLine(L"DAEMON_STOP_REASON=TIMEOUT");
                break;
            }
            if (maxWaitMs - elapsedMs < waitChunk) {
                waitChunk = maxWaitMs - elapsedMs;
            }
        }
        DWORD wr = WaitForSingleObject(hStopEvent, waitChunk);
        if (wr == 0) { // WAIT_OBJECT_0: Stop event signaled
            OutLine(L"DAEMON_STOP_REASON=STOP_SIGNALED");
            break;
        }
        elapsedMs += waitChunk;
        OutDec(L"DAEMON_HEARTBEAT_SEC=", elapsedMs / 1000);
    }

    // 8. Clean shutdown
    OutLine(L"DAEMON_CLOSING_SWDEVICE=YES");
    pfnSwDeviceClose(hSwDevice);
    OutLine(L"DAEMON_STOPPED=YES");
    CloseHandle(hStopEvent);
    CloseHandle(hMutex);
    FreeLibrary(hCfgMgr);
    OutLine(L"RESULT=SUCCESS");
    return true;
}

bool StopDaemon() {
    HANDLE hStop = OpenEventW(EVENT_MODIFY_STATE, FALSE, L"Local\\FluxDevNodeStopEvent");
    if (!hStop) {
        OutLine(L"STOP_EVENT_NOT_FOUND=YES");
        OutLine(L"RESULT=NOT_RUNNING");
        return false;
    }
    SetEvent(hStop);
    CloseHandle(hStop);
    OutLine(L"STOP_SIGNAL_SENT=YES");
    OutLine(L"RESULT=SUCCESS");
    return true;
}

LONG SetResolution(DWORD width, DWORD height) {
    HMODULE hUser32 = LoadLibraryW(L"user32.dll");
    if (!hUser32) {
        PrintWin32Failure(L"LoadLibrary(user32.dll)", GetLastError());
        return -1;
    }
    typedef LONG (WINAPI *PFN_ChangeDisplaySettingsW)(DEVMODEW* lpDevMode, DWORD dwflags);
    auto pfnChangeDisplaySettingsW = reinterpret_cast<PFN_ChangeDisplaySettingsW>(GetProcAddress(hUser32, "ChangeDisplaySettingsW"));
    if (!pfnChangeDisplaySettingsW) {
        ErrLine(L"ChangeDisplaySettingsW not found in user32.dll");
        FreeLibrary(hUser32);
        return -1;
    }

    DEVMODEW dm = {};
    dm.dmSize = sizeof(dm);
    dm.dmPelsWidth = width;
    dm.dmPelsHeight = height;
    dm.dmFields = 0x00080000L | 0x00100000L; // DM_PELSWIDTH | DM_PELSHEIGHT

    LONG result = pfnChangeDisplaySettingsW(&dm, 0);
    FreeLibrary(hUser32);
    return result;
}

bool RunResAgent(const wchar_t* requestPath, DWORD pollIntervalMs) {
    if (!requestPath || requestPath[0] == L'\0') {
        requestPath = L"D:\\flux_resolution_request.txt";
    }
    if (pollIntervalMs == 0) {
        pollIntervalMs = 250;
    }

    HANDLE hStopEvent = CreateEventW(nullptr, TRUE, FALSE, L"Local\\FluxResAgentStopEvent");
    if (!hStopEvent) {
        PrintWin32Failure(L"CreateEventW(resagent-stop)", GetLastError());
        return false;
    }
    ResetEvent(hStopEvent);

    Out(L"RESAGENT_REQUEST_PATH="); OutLine(requestPath);
    OutDec(L"RESAGENT_POLL_INTERVAL_MS=", pollIntervalMs);
    OutLine(L"RESAGENT_STATUS=RUNNING");

    DWORD elapsedMs = 0;
    while (true) {
        DWORD wr = WaitForSingleObject(hStopEvent, pollIntervalMs);
        if (wr == 0) { // WAIT_OBJECT_0
            OutLine(L"RESAGENT_STOP_REASON=STOP_SIGNALED");
            break;
        }

        elapsedMs += pollIntervalMs;
        if (elapsedMs % 30000 < pollIntervalMs) {
            OutDec(L"RESAGENT_HEARTBEAT_SEC=", elapsedMs / 1000);
        }

        // Check primary request path, fallback to Public if not found
        const wchar_t* activePath = requestPath;
        HANDLE hFile = CreateFileW(activePath, 0x80000000L /* GENERIC_READ */, 0x00000001 | 0x00000002 /* FILE_SHARE_READ | FILE_SHARE_WRITE */,
                                   nullptr, 3 /* OPEN_EXISTING */, 0x00000080 /* FILE_ATTRIBUTE_NORMAL */, nullptr);
        if (hFile == INVALID_HANDLE_VALUE) {
            activePath = L"C:\\Users\\Public\\flux_resolution_request.txt";
            hFile = CreateFileW(activePath, 0x80000000L, 0x00000001 | 0x00000002,
                                nullptr, 3, 0x00000080, nullptr);
        }

        if (hFile != INVALID_HANDLE_VALUE) {
            char buf[256] = {};
            DWORD bytesRead = 0;
            ReadFile(hFile, buf, sizeof(buf) - 1, &bytesRead, nullptr);
            CloseHandle(hFile);

            // Delete request file once read
            DeleteFileW(activePath);

            if (bytesRead > 0) {
                buf[bytesRead] = '\0';
                DWORD w = 0, h = 0;
                int i = 0;
                while (buf[i] == ' ' || buf[i] == '\t' || buf[i] == '\r' || buf[i] == '\n') i++;
                while (buf[i] >= '0' && buf[i] <= '9') { w = w * 10 + (buf[i] - '0'); i++; }
                while (buf[i] == ' ' || buf[i] == '\t' || buf[i] == 'x' || buf[i] == 'X') i++;
                while (buf[i] >= '0' && buf[i] <= '9') { h = h * 10 + (buf[i] - '0'); i++; }

                if (w > 0 && h > 0) {
                    Out(L"RESAGENT_RECEIVED_MODE="); OutDec(L"", w); Out(L"x"); OutDec(L"", h);
                    LONG res = SetResolution(w, h);
                    Out(L"RESAGENT_SET_RESULT=");
                    if (res == 0) {
                        OutLine(L"SUCCESS");
                    } else {
                        OutDec(L"FAIL_CODE=", static_cast<DWORD>(res));
                    }

                    // Write status file
                    HANDLE hStatus = CreateFileW(L"D:\\flux_resolution_status.txt", 0x40000000L /* GENERIC_WRITE */, 0x00000001,
                                                 nullptr, 2 /* CREATE_ALWAYS */, 0x00000080, nullptr);
                    if (hStatus == INVALID_HANDLE_VALUE) {
                        hStatus = CreateFileW(L"C:\\Users\\Public\\flux_resolution_status.txt", 0x40000000L, 0x00000001,
                                              nullptr, 2, 0x00000080, nullptr);
                    }
                    if (hStatus != INVALID_HANDLE_VALUE) {
                        char statusBuf[256];
                        int slen = 0;
                        const char* sStr = (res == 0) ? "SUCCESS" : "FAILED";
                        char numW[16], numH[16], numC[16];
                        int niw = 0, nih = 0, nic = 0;
                        DWORD tw = w, th = h, tc = static_cast<DWORD>(res);
                        if (tw == 0) numW[niw++] = '0'; else while (tw > 0) { numW[niw++] = '0' + (tw % 10); tw /= 10; }
                        if (th == 0) numH[nih++] = '0'; else while (th > 0) { numH[nih++] = '0' + (th % 10); th /= 10; }
                        if (tc == 0) numC[nic++] = '0'; else while (tc > 0) { numC[nic++] = '0' + (tc % 10); tc /= 10; }

                        auto appendStr = [&](const char* s) { while (*s) statusBuf[slen++] = *s++; };
                        appendStr("STATUS="); appendStr(sStr); appendStr("\r\nWIDTH=");
                        for (int k = niw - 1; k >= 0; k--) statusBuf[slen++] = numW[k];
                        appendStr("\r\nHEIGHT=");
                        for (int k = nih - 1; k >= 0; k--) statusBuf[slen++] = numH[k];
                        appendStr("\r\nCODE=");
                        for (int k = nic - 1; k >= 0; k--) statusBuf[slen++] = numC[k];
                        appendStr("\r\n");

                        DWORD written = 0;
                        WriteFile(hStatus, statusBuf, slen, &written, nullptr);
                        CloseHandle(hStatus);
                    }
                }
            }
        }
    }

    CloseHandle(hStopEvent);
    OutLine(L"RESAGENT_STOPPED=YES");
    OutLine(L"RESULT=SUCCESS");
    return true;
}

bool StopResAgent() {
    HANDLE hStop = OpenEventW(EVENT_MODIFY_STATE, FALSE, L"Local\\FluxResAgentStopEvent");
    if (!hStop) {
        OutLine(L"STOP_EVENT_NOT_FOUND=YES");
        OutLine(L"RESULT=NOT_RUNNING");
        return false;
    }
    SetEvent(hStop);
    CloseHandle(hStop);
    OutLine(L"STOP_SIGNAL_SENT=YES");
    OutLine(L"RESULT=SUCCESS");
    return true;
}

} // namespace

int wmain(int argc, wchar_t* argv[]) {
    if (argc == 3 && StrICmp(argv[1], L"count") == 0) {
        DWORD count = 0;
        if (!CountHardwareIds(argv[2], &count)) {
            OutLine(L"RESULT=FAIL");
            return 1;
        }
        OutDec(L"COUNT=", count);
        OutLine(L"RESULT=SUCCESS");
        return 0;
    }

    if (argc == 3 && StrICmp(argv[1], L"query") == 0) {
        if (!QueryHardwareId(argv[2])) {
            OutLine(L"RESULT=FAIL");
            return 1;
        }
        OutLine(L"RESULT=SUCCESS");
        return 0;
    }

    if (argc == 3 && StrICmp(argv[1], L"remove") == 0) {
        if (!RemoveDeviceInstance(argv[2])) {
            OutLine(L"RESULT=FAIL");
            return 1;
        }
        return 0;
    }

    if (argc >= 2 && StrICmp(argv[1], L"stop") == 0) {
        if (!StopDaemon()) {
            return 1;
        }
        return 0;
    }

    if (argc == 4 && StrICmp(argv[1], L"setres") == 0) {
        DWORD width = ParseDec(argv[2]);
        DWORD height = ParseDec(argv[3]);
        if (width == 0 || height == 0) {
            ErrLine(L"Invalid resolution parameters");
            return 2;
        }
        Out(L"REQUESTED_WIDTH="); OutDec(L"", width);
        Out(L"REQUESTED_HEIGHT="); OutDec(L"", height);
        LONG res = SetResolution(width, height);
        Out(L"CHANGE_DISPLAY_SETTINGS_RESULT=");
        if (res == 0) {
            OutLine(L"DISP_CHANGE_SUCCESSFUL (0)");
            OutLine(L"RESULT=SUCCESS");
            return 0;
        } else {
            OutDec(L"ERROR_CODE=", static_cast<DWORD>(res));
            OutLine(L"RESULT=FAIL");
            return 1;
        }
    }

    if (argc >= 2 && StrICmp(argv[1], L"resagent") == 0) {
        const wchar_t* path = (argc >= 3) ? argv[2] : L"D:\\flux_resolution_request.txt";
        DWORD pollMs = (argc >= 4) ? ParseDec(argv[3]) : 250;
        if (!RunResAgent(path, pollMs)) {
            return 1;
        }
        return 0;
    }

    if (argc >= 2 && (StrICmp(argv[1], L"stop-resagent") == 0 || StrICmp(argv[1], L"stopres") == 0)) {
        if (!StopResAgent()) {
            return 1;
        }
        return 0;
    }

    if (argc >= 3 && (StrICmp(argv[1], L"daemon") == 0 || StrICmp(argv[1], L"keep-alive") == 0)) {
        const wchar_t* hwId = argv[2];
        DWORD durationSeconds = 0;
        GUID classGuid = { 0x4D36E968, 0xE325, 0x11CE, { 0xBF, 0xC1, 0x08, 0x00, 0x2B, 0xE1, 0x03, 0x18 } };
        if (argc >= 4) {
            durationSeconds = ParseDec(argv[3]);
        }
        if (argc >= 5) {
            if (FAILED(CLSIDFromString(argv[4], &classGuid))) {
                Err(L"Invalid class GUID: "); ErrLine(argv[4]);
                return 2;
            }
        }
        Out(L"DAEMON_HARDWARE_ID="); OutLine(hwId);
        OutDec(L"DAEMON_DURATION_SEC=", durationSeconds);
        if (!RunDaemon(hwId, classGuid, durationSeconds)) {
            return 1;
        }
        return 0;
    }

    if ((argc == 3 || argc == 4) && (StrICmp(argv[1], L"create") == 0 || StrICmp(argv[1], L"create-swd") == 0)) {
        const wchar_t* hwId = argv[2];
        GUID classGuid = { 0x4D36E968, 0xE325, 0x11CE, { 0xBF, 0xC1, 0x08, 0x00, 0x2B, 0xE1, 0x03, 0x18 } };
        if (argc == 4) {
            if (FAILED(CLSIDFromString(argv[3], &classGuid))) {
                Err(L"Invalid class GUID: "); ErrLine(argv[3]);
                return 2;
            }
        }
        Out(L"REQUESTED_HARDWARE_ID="); OutLine(hwId);
        if (!CreateSoftwareDevice(hwId, classGuid)) {
            return 1;
        }
        return 0;
    }

    ErrLine(L"Usage: FluxDevNode.exe count <hardware-id>");
    ErrLine(L"   or: FluxDevNode.exe query <hardware-id>");
    ErrLine(L"   or: FluxDevNode.exe create <hardware-id> [class-guid]");
    ErrLine(L"   or: FluxDevNode.exe daemon <hardware-id> [duration-sec] [class-guid]");
    ErrLine(L"   or: FluxDevNode.exe stop");
    ErrLine(L"   or: FluxDevNode.exe setres <width> <height>");
    ErrLine(L"   or: FluxDevNode.exe resagent [request-path] [poll-ms]");
    ErrLine(L"   or: FluxDevNode.exe stop-resagent");
    ErrLine(L"   or: FluxDevNode.exe remove <instance-id>");
    return 2;
}

#if !defined(_MSC_VER) || defined(__clang__)
extern "C" void mainCRTStartup() {
    int argc = 0;
    wchar_t** argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    int rc = wmain(argc, argv);
    LocalFree(argv);
    ExitProcess((unsigned int)rc);
}
#endif
