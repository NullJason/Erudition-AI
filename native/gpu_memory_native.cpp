#include <jni.h>
#include <windows.h>
#include <dxgi1_4.h>
#include <wrl/client.h>
#include <combaseapi.h>

using Microsoft::WRL::ComPtr;

static bool query_memory_info(IDXGIAdapter3* adapter3, DXGI_MEMORY_SEGMENT_GROUP group, DXGI_QUERY_VIDEO_MEMORY_INFO& info) {
    return SUCCEEDED(adapter3->QueryVideoMemoryInfo(0, group, &info));
}

extern "C" JNIEXPORT jlongArray JNICALL
Java_com_example_edutool_GpuMemoryNative_queryVideoMemoryNative(JNIEnv* env, jclass) {
    jlong values[6] = { -1, -1, -1, -1, -1, -1 };

    HRESULT hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    const bool com_initialized = SUCCEEDED(hr) || hr == RPC_E_CHANGED_MODE;

    ComPtr<IDXGIFactory1> factory;
    if (FAILED(CreateDXGIFactory1(IID_PPV_ARGS(&factory))) || !factory) {
        jlongArray arr = env->NewLongArray(6);
        env->SetLongArrayRegion(arr, 0, 6, values);
        if (com_initialized && hr == S_OK) CoUninitialize();
        return arr;
    }

    ComPtr<IDXGIAdapter1> adapter1;
    for (UINT i = 0; factory->EnumAdapters1(i, &adapter1) != DXGI_ERROR_NOT_FOUND; ++i) {
        DXGI_ADAPTER_DESC1 desc{};
        if (FAILED(adapter1->GetDesc1(&desc))) {
            adapter1.Reset();
            continue;
        }

        if (desc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) {
            adapter1.Reset();
            continue;
        }

        ComPtr<IDXGIAdapter3> adapter3;
        if (SUCCEEDED(adapter1.As(&adapter3)) && adapter3) {
            DXGI_QUERY_VIDEO_MEMORY_INFO localInfo{};
            DXGI_QUERY_VIDEO_MEMORY_INFO nonLocalInfo{};

            if (query_memory_info(adapter3.Get(), DXGI_MEMORY_SEGMENT_GROUP_LOCAL, localInfo)) {
                values[0] = static_cast<jlong>(localInfo.Budget);
                values[1] = static_cast<jlong>(localInfo.CurrentUsage);
                values[2] = static_cast<jlong>(localInfo.AvailableForReservation);
            }

            if (query_memory_info(adapter3.Get(), DXGI_MEMORY_SEGMENT_GROUP_NON_LOCAL, nonLocalInfo)) {
                values[3] = static_cast<jlong>(nonLocalInfo.Budget);
                values[4] = static_cast<jlong>(nonLocalInfo.CurrentUsage);
                values[5] = static_cast<jlong>(nonLocalInfo.AvailableForReservation);
            }

            break;
        }

        adapter1.Reset();
    }

    jlongArray arr = env->NewLongArray(6);
    env->SetLongArrayRegion(arr, 0, 6, values);

    if (com_initialized && hr == S_OK) {
        CoUninitialize();
    }

    return arr;
}