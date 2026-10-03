#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <setupapi.h>
#include <objbase.h>

#include <iostream>
#include <string>
#include <vector>

#pragma comment(lib, "setupapi.lib")
#pragma comment(lib, "ole32.lib")

namespace {

void PrintWin32Failure(const wchar_t* api, DWORD error) {
    wchar_t* message = nullptr;
    const DWORD flags = FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM |
                        FORMAT_MESSAGE_IGNORE_INSERTS;
    const DWORD length = FormatMessageW(flags, nullptr, error, 0,
                                        reinterpret_cast<wchar_t*>(&message), 0, nullptr);
    std::wcerr << api << L" FAILED GetLastError=" << error;
    if (length != 0 && message != nullptr) {
        std::wcerr << L" MESSAGE=" << message;
        LocalFree(message);
    }
    std::wcerr << std::endl;
}

bool ContainsHardwareId(const BYTE* data, DWORD byteCount, const std::wstring& wanted) {
    if (data == nullptr || byteCount < sizeof(wchar_t)) {
        return false;
    }

    const wchar_t* current = reinterpret_cast<const wchar_t*>(data);
    const wchar_t* end = reinterpret_cast<const wchar_t*>(data + byteCount);
    while (current < end && *current != L'\0') {
        if (_wcsicmp(current, wanted.c_str()) == 0) {
            return true;
        }
        current += wcslen(current) + 1;
    }
    return false;
}

bool HardwareIdAlreadyExists(const std::wstring& hardwareId, bool* alreadyExists) {
    *alreadyExists = false;
    HDEVINFO deviceInfoSet = SetupDiGetClassDevsW(nullptr, nullptr, nullptr,
                                                   DIGCF_ALLCLASSES | DIGCF_PRESENT);
    if (deviceInfoSet == INVALID_HANDLE_VALUE) {
        PrintWin32Failure(L"SetupDiGetClassDevs", GetLastError());
        return false;
    }

    for (DWORD index = 0;; ++index) {
        SP_DEVINFO_DATA deviceInfoData{};
        deviceInfoData.cbSize = sizeof(deviceInfoData);
        if (!SetupDiEnumDeviceInfo(deviceInfoSet, index, &deviceInfoData)) {
            const DWORD error = GetLastError();
            if (error == ERROR_NO_MORE_ITEMS) {
                break;
            }
            PrintWin32Failure(L"SetupDiEnumDeviceInfo", error);
            SetupDiDestroyDeviceInfoList(deviceInfoSet);
            return false;
        }

        DWORD propertyType = 0;
        DWORD requiredBytes = 0;
        if (!SetupDiGetDeviceRegistryPropertyW(deviceInfoSet, &deviceInfoData,
                                               SPDRP_HARDWAREID, &propertyType,
                                               nullptr, 0, &requiredBytes)) {
            const DWORD error = GetLastError();
            if (error == ERROR_INVALID_DATA || error == ERROR_FILE_NOT_FOUND) {
                continue;
            }
            if (error != ERROR_INSUFFICIENT_BUFFER) {
                PrintWin32Failure(L"SetupDiGetDeviceRegistryProperty(size)", error);
                SetupDiDestroyDeviceInfoList(deviceInfoSet);
                return false;
            }
        }

        if (propertyType != REG_MULTI_SZ || requiredBytes == 0) {
            continue;
        }

        std::vector<BYTE> hardwareIds(requiredBytes);
        if (!SetupDiGetDeviceRegistryPropertyW(deviceInfoSet, &deviceInfoData,
                                               SPDRP_HARDWAREID, &propertyType,
                                               hardwareIds.data(), requiredBytes, nullptr)) {
            PrintWin32Failure(L"SetupDiGetDeviceRegistryProperty", GetLastError());
            SetupDiDestroyDeviceInfoList(deviceInfoSet);
            return false;
        }

        if (propertyType == REG_MULTI_SZ &&
            ContainsHardwareId(hardwareIds.data(), requiredBytes, hardwareId)) {
            *alreadyExists = true;
            break;
        }
    }

    if (!SetupDiDestroyDeviceInfoList(deviceInfoSet)) {
        PrintWin32Failure(L"SetupDiDestroyDeviceInfoList(enumeration)", GetLastError());
        return false;
    }
    return true;
}

bool CreateRootDevice(const std::wstring& hardwareId, const GUID& classGuid) {
    HDEVINFO deviceInfoSet = SetupDiCreateDeviceInfoList(&classGuid, nullptr);
    std::wcout << L"CREATE_DEVICE_INFO_LIST="
               << (deviceInfoSet == INVALID_HANDLE_VALUE ? L"FAIL" : L"PASS") << std::endl;
    if (deviceInfoSet == INVALID_HANDLE_VALUE) {
        PrintWin32Failure(L"SetupDiCreateDeviceInfoList", GetLastError());
        return false;
    }

    SP_DEVINFO_DATA deviceInfoData{};
    deviceInfoData.cbSize = sizeof(deviceInfoData);
    if (!SetupDiCreateDeviceInfoW(deviceInfoSet, hardwareId.c_str(), &classGuid, nullptr,
                                  nullptr, DICD_GENERATE_ID, &deviceInfoData)) {
        std::wcout << L"CREATE_DEVICE_INFO=FAIL" << std::endl;
        PrintWin32Failure(L"SetupDiCreateDeviceInfo", GetLastError());
        SetupDiDestroyDeviceInfoList(deviceInfoSet);
        return false;
    }
    std::wcout << L"CREATE_DEVICE_INFO=PASS" << std::endl;

    std::vector<wchar_t> multiSz(hardwareId.begin(), hardwareId.end());
    multiSz.push_back(L'\0');
    multiSz.push_back(L'\0');
    const DWORD multiSzBytes = static_cast<DWORD>(multiSz.size() * sizeof(wchar_t));
    if (!SetupDiSetDeviceRegistryPropertyW(deviceInfoSet, &deviceInfoData, SPDRP_HARDWAREID,
                                           reinterpret_cast<const BYTE*>(multiSz.data()),
                                           multiSzBytes)) {
        std::wcout << L"SET_HARDWARE_ID=FAIL" << std::endl;
        PrintWin32Failure(L"SetupDiSetDeviceRegistryProperty(SPDRP_HARDWAREID)", GetLastError());
        SetupDiDestroyDeviceInfoList(deviceInfoSet);
        return false;
    }
    std::wcout << L"SET_HARDWARE_ID=PASS" << std::endl;

    if (!SetupDiCallClassInstaller(DIF_REGISTERDEVICE, deviceInfoSet, &deviceInfoData)) {
        std::wcout << L"REGISTER_DEVICE=FAIL" << std::endl;
        PrintWin32Failure(L"SetupDiCallClassInstaller(DIF_REGISTERDEVICE)", GetLastError());
        SetupDiDestroyDeviceInfoList(deviceInfoSet);
        return false;
    }
    std::wcout << L"REGISTER_DEVICE=PASS" << std::endl;

    if (!SetupDiDestroyDeviceInfoList(deviceInfoSet)) {
        PrintWin32Failure(L"SetupDiDestroyDeviceInfoList(creation)", GetLastError());
        return false;
    }
    return true;
}

} // namespace

int wmain(int argc, wchar_t* argv[]) {
    if (argc != 4 || _wcsicmp(argv[1], L"create") != 0) {
        std::wcerr << L"Usage: FluxDevNode.exe create <hardware-id> <class-guid>" << std::endl;
        return 2;
    }

    const std::wstring hardwareId = argv[2];
    GUID classGuid{};
    if (FAILED(CLSIDFromString(argv[3], &classGuid))) {
        std::wcerr << L"Invalid class GUID: " << argv[3] << std::endl;
        return 2;
    }

    std::wcout << L"REQUESTED_HARDWARE_ID=" << hardwareId << std::endl;
    std::wcout << L"REQUESTED_CLASS_GUID=" << argv[3] << std::endl;

    bool alreadyExists = false;
    if (!HardwareIdAlreadyExists(hardwareId, &alreadyExists)) {
        std::wcout << L"RESULT=FAIL" << std::endl;
        return 1;
    }
    std::wcout << L"ALREADY_EXISTS=" << (alreadyExists ? L"YES" : L"NO") << std::endl;
    if (alreadyExists) {
        std::wcout << L"RESULT=ALREADY_EXISTS" << std::endl;
        return 0;
    }

    if (!CreateRootDevice(hardwareId, classGuid)) {
        std::wcout << L"RESULT=FAIL" << std::endl;
        return 1;
    }

    std::wcout << L"RESULT=SUCCESS" << std::endl;
    return 0;
}
