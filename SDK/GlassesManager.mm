#import "GlassesManager.h"
#include "viture_glasses_provider.h"
#include "viture_device_carina.h"
#import <CoreVideo/CoreVideo.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/usb/IOUSBLib.h>

@implementation GlassesManager {
    XRDeviceProviderHandle _handle;
    void (^_frameHandler)(CVPixelBufferRef, CVPixelBufferRef);
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
    int pid = detectViturePID();
    if (pid == 0) {
        NSLog(@"[Error] VITURE Glass Not Found in USB.");
        return NO;
    }
    NSLog(@"[Success] VITURE Glass Found! PID: 0x%04X", pid);

    _handle = xr_device_provider_create(pid);
    if (!_handle) return NO;
    
    xr_device_provider_register_callbacks_carina(_handle, nullptr, nullptr, nullptr, GlobalCameraCallback);
    
    if (xr_device_provider_initialize(_handle) != 0) return NO;
    if (xr_device_provider_start(_handle) != 0) return NO;
    
    return YES;
}

- (void)startStreamingWithHandler:(void (^)(CVPixelBufferRef, CVPixelBufferRef))handler {
    _frameHandler = handler;
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
