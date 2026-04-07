#import "GlassesManager.h"
#include "viture_glasses_provider.h"
#include "viture_device_carina.h"
#include "viture_device.h"
#include "viture_protocol_public.h"
#import <CoreVideo/CoreVideo.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/usb/IOUSBLib.h>
#include <atomic>
#include <thread>
#include <chrono>

@implementation GlassesManager {
    XRDeviceProviderHandle _handle;
    void (^_frameHandler)(CVPixelBufferRef, CVPixelBufferRef);
    void (^_poseHandler)(float, float, float, float, float, float, float);
    
    int _deviceType;
    std::atomic<bool> _poseThreadRunning;
    std::thread _poseThread;
}

+ (instancetype)sharedManager {
    static GlassesManager *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[self alloc] init];
    });
    return shared;
}

static bool getUSBProperty(io_service_t service, const char* key, uint16_t* outValue) {
    CFStringRef keyStr = CFStringCreateWithCString(kCFAllocatorDefault, key, kCFStringEncodingUTF8);
    CFTypeRef prop = IORegistryEntryCreateCFProperty(service, keyStr, kCFAllocatorDefault, 0);
    CFRelease(keyStr);
    if (!prop) return false;

    bool success = false;
    if (CFNumberGetTypeID() == CFGetTypeID(prop)) {
        success = CFNumberGetValue((CFNumberRef)prop, kCFNumberShortType, outValue);
    }
    CFRelease(prop);
    return success;
}

static int detectViturePID() {
    CFMutableDictionaryRef matchingDict = IOServiceMatching(kIOUSBDeviceClassName);
    if (!matchingDict) return 0;

    io_iterator_t iterator = 0;
    if (IOServiceGetMatchingServices(0, matchingDict, &iterator) != KERN_SUCCESS) return 0;

    io_service_t service;
    while ((service = IOIteratorNext(iterator))) {
        uint16_t vid = 0, pid = 0;
        if (getUSBProperty(service, kUSBVendorID, &vid) && getUSBProperty(service, kUSBProductID, &pid)) {
            if (vid == 0x35CA) {
                IOObjectRelease(service);
                IOObjectRelease(iterator);
                return pid;
            }
        }
        IOObjectRelease(service);
    }
    IOObjectRelease(iterator);
    return 0;
}

static void GlobalCameraCallback(char* image_left0, char* image_right0,
                                 char* image_left1, char* image_right1,
                                 double timestamp, int width, int height) {
    if (!image_left0 || !image_right0) return;
    [[GlassesManager sharedManager] processRawFrameLeft:image_left0 right:image_right0 width:width height:height];
}

- (BOOL)setupAndConnect {
    if (_handle) return YES;

    int pid = detectViturePID();
    if (pid == 0) {
        NSLog(@"[GlassesManager] [Error] VITURE Glass Not Found in USB.");
        return NO;
    }
    NSLog(@"[GlassesManager] [Success] VITURE Glass Found! PID: 0x%04X", pid);

    _handle = xr_device_provider_create(pid);
    if (!_handle) {
        NSLog(@"[GlassesManager] [Error] Failed to create device provider handle.");
        return NO;
    }
    
    _deviceType = xr_device_provider_get_device_type(_handle);
    NSLog(@"[GlassesManager] Detected Device Type ID: %d", _deviceType);
    
    // Callback (Carina)
    if (_deviceType == XR_DEVICE_TYPE_VITURE_CARINA) {
        NSLog(@"[GlassesManager] Device recognized as Carina. Registering Carina callbacks...");
        xr_device_provider_register_callbacks_carina(_handle, nullptr, nullptr, nullptr, GlobalCameraCallback);
    } else {
        NSLog(@"[GlassesManager] Device is NOT Carina. Callbacks might need different registration.");
    }
    
    if (xr_device_provider_initialize(_handle) != 0) {
        NSLog(@"[GlassesManager] [Error] Failed to initialize device provider.");
        xr_device_provider_destroy(_handle);
        _handle = nullptr;
        return NO;
    }
    
    NSLog(@"[GlassesManager] Setting display mode to 3840x1200 (3D Mode) BEFORE start...");
    int modeRes = xr_device_provider_set_display_mode(_handle, VITURE_DISPLAY_MODE_3840_1200_90HZ);
    NSLog(@"[GlassesManager] Display mode switch result: %d (0 = Success)", modeRes);
    
    // 設定が反映されるまで少しだけ待機（USBエンドポイントの再構成を待つ）
    [NSThread sleepForTimeInterval:0.5];
    
    if (xr_device_provider_start(_handle) != 0) {
        NSLog(@"[GlassesManager] [Error] Failed to start device provider.");
        xr_device_provider_shutdown(_handle);
        xr_device_provider_destroy(_handle);
        _handle = nullptr;
        return NO;
    }
    
    NSLog(@"[GlassesManager] Successfully started device streaming.");
    
    // もし start() 前の変更が失敗していた場合、念のため起動後にも非同期で再トライする
    if (modeRes != 0) {
        XRDeviceProviderHandle currentHandle = _handle;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            if (currentHandle) {
                NSLog(@"[GlassesManager] Retrying display mode switch to 3840x1200 AFTER start...");
                int retryRes = xr_device_provider_set_display_mode(currentHandle, VITURE_DISPLAY_MODE_3840_1200_90HZ);
                NSLog(@"[GlassesManager] Retry display mode switch result: %d", retryRes);
            }
        });
    }
    
    return YES;
}

- (void)startStreamingWithHandler:(void (^)(CVPixelBufferRef, CVPixelBufferRef))handler {
    _frameHandler = handler;
}

- (void)startPosePollingWithHandler:(void (^)(float, float, float, float, float, float, float))handler {
    if (_deviceType != XR_DEVICE_TYPE_VITURE_CARINA || !_handle) return;
    
    _poseHandler = handler;
    
    if (!_poseThreadRunning.load()) {
        _poseThreadRunning.store(true);
        _poseThread = std::thread([self]() {
            [self posePollingLoop];
        });
    }
}

- (void)posePollingLoop {
    const int interval_ms = 12; // 120Hz
    auto next_time = std::chrono::steady_clock::now();
    
    float pose[7] = {0};
    int pose_status = 0;
    
    while (_poseThreadRunning.load()) {
        if (_handle) {
            int result = xr_device_provider_get_gl_pose_carina(_handle, pose, 0.0, &pose_status);
            if (result == 0 && _poseHandler) {
                // バックグラウンドスレッドで高頻度でコールバックを実行
                _poseHandler(pose[0], pose[1], pose[2], pose[3], pose[4], pose[5], pose[6]);
            }
        }
        
        next_time += std::chrono::milliseconds(interval_ms);
        std::this_thread::sleep_until(next_time);
    }
}

- (void)disconnect {
    if (!_handle) return;
    
    NSLog(@"[GlassesManager] Disconnecting...");

    // 1. Poseスレッドを安全に停止
    if (_poseThreadRunning.load()) {
        _poseThreadRunning.store(false);
        if (_poseThread.joinable()) {
            _poseThread.join();
        }
    }
    
    XRDeviceProviderHandle handleToClose = _handle;
    
    // メインスレッドからポインタを外して、以降のコールバックを防止
    _handle = nullptr;
    _frameHandler = nil;
    _poseHandler = nil;
    
    // 2. 解像度を元の 1920x1200 に戻す処理と終了処理をバックグラウンドで行う
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSLog(@"[GlassesManager] Restoring display mode to 1920x1200...");
        // デバイスタイプにかかわらず、復元を試みる
        int res = xr_device_provider_set_display_mode(handleToClose, VITURE_DISPLAY_MODE_1920_1200_120HZ);
        NSLog(@"[GlassesManager] Restore mode result: %d (0 = Success)", res);
        
        // グラス側が切り替え処理を終えるまで待機
        [NSThread sleepForTimeInterval:1.0];
        
        // 3. SDKのクリーンアップ
        xr_device_provider_stop(handleToClose);
        xr_device_provider_shutdown(handleToClose);
        xr_device_provider_destroy(handleToClose);
        
        NSLog(@"[GlassesManager] Disconnected and cleaned up.");
    });
}

- (CVPixelBufferRef)createPixelBufferFromData:(char*)rawData width:(int)w height:(int)h {
    CVPixelBufferRef pixelBuffer = NULL;
    CVReturn status = CVPixelBufferCreate(kCFAllocatorDefault, w, h,
                                          kCVPixelFormatType_OneComponent8,
                                          NULL, &pixelBuffer);
    if (status == kCVReturnSuccess && pixelBuffer != NULL) {
        CVPixelBufferLockBaseAddress(pixelBuffer, 0);
        void *baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer);
        size_t bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer);
        for (int i = 0; i < h; i++) {
            memcpy((uint8_t*)baseAddress + (i * bytesPerRow),
                   (uint8_t*)rawData + (i * w), w);
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
        return pixelBuffer;
    }
    return NULL;
}

- (void)processRawFrameLeft:(char*)leftData right:(char*)rightData width:(int)w height:(int)h {
    if (!_frameHandler) return;

    CVPixelBufferRef leftBuffer = [self createPixelBufferFromData:leftData width:w height:h];
    CVPixelBufferRef rightBuffer = [self createPixelBufferFromData:rightData width:w height:h];
    
    if (leftBuffer && rightBuffer) {
        _frameHandler(leftBuffer, rightBuffer);
    }
    
    if (leftBuffer) CVPixelBufferRelease(leftBuffer);
    if (rightBuffer) CVPixelBufferRelease(rightBuffer);
}

@end
