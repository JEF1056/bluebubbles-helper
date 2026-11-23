#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <assert.h>
#import <fcntl.h>
#import <mach/mach_time.h>
#import <stdatomic.h>
#import <stdint.h>
#import <stdio.h>
#import <string.h>
#import <sys/mman.h>
#import <sys/stat.h>
#import <unistd.h>
#import <dispatch/dispatch.h>

extern CMSampleBufferRef BBCameraHookCreateSwappedSampleBuffer(CMSampleBufferRef origSampleBuffer, const char *ringPath);
extern BOOL BBCameraHookInstallOnClasses(Class baseCls, Class tundraCls);
extern BOOL BBCameraHookInstallSuspendedOnClasses(Class baseCls, Class tundraCls, Class dalCls);
extern void BBCameraHookSetRingPathForTesting(const char *path);
extern void BBCameraHookSetActiveFlagPathForTesting(const char *path);

@interface MockSuspendedDevice : NSObject
@property (nonatomic, assign) BOOL rawSuspended;
- (BOOL)isSuspended;
@end
@implementation MockSuspendedDevice
- (BOOL)isSuspended {
    return self.rawSuspended;
}
@end

@interface MockPumpSession : NSObject
@property (nonatomic, assign, getter=isRunning) BOOL running;
@end
@implementation MockPumpSession
@end

@interface MockPumpPort : NSObject
@property (nonatomic, assign) CMClockRef clock;
@property (nonatomic, assign) CMFormatDescriptionRef formatDescription;
@end
@implementation MockPumpPort
@end

@interface MockPumpConnection : NSObject
@property (nonatomic, assign, getter=isEnabled) BOOL enabled;
@property (nonatomic, assign, getter=isActive) BOOL active;
@property (nonatomic, strong) NSArray *inputPorts;
@end
@implementation MockPumpConnection
@end

@interface MockPumpCaptureOutput : NSObject
@property (nonatomic, strong) id receivedDelegate;
@property (nonatomic, strong) dispatch_queue_t receivedQueue;
@property (nonatomic, strong) MockPumpSession *session;
@property (nonatomic, strong) MockPumpConnection *videoConnection;
@property (nonatomic, strong) NSDictionary *videoSettings;
- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)sampleBufferDelegate
                          queue:(dispatch_queue_t)sampleBufferCallbackQueue;
- (AVCaptureConnection *)connectionWithMediaType:(AVMediaType)mediaType;
@end

@implementation MockPumpCaptureOutput
- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)sampleBufferDelegate
                          queue:(dispatch_queue_t)sampleBufferCallbackQueue {
    _receivedDelegate = sampleBufferDelegate;
    _receivedQueue = sampleBufferCallbackQueue;
}
- (AVCaptureConnection *)connectionWithMediaType:(AVMediaType)mediaType {
    if ([mediaType isEqualToString:AVMediaTypeVideo]) {
        return (AVCaptureConnection *)_videoConnection;
    }
    return nil;
}
@end

@interface MockPumpDelegate : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate> {
    _Atomic int _frameCount;
}
@property (nonatomic, assign) uint32_t lastWidth;
@property (nonatomic, assign) uint32_t lastHeight;
@property (nonatomic, assign) BOOL lastHadIOSurface;
@property (nonatomic, assign) CMTime lastPTS;
@property (nonatomic, assign) int ptsViolations;
- (int)currentFrameCount;
@end

@implementation MockPumpDelegate
- (instancetype)init {
    self = [super init];
    if (self) {
        _lastPTS = kCMTimeInvalid;
    }
    return self;
}
- (int)currentFrameCount {
    return atomic_load_explicit(&_frameCount, memory_order_relaxed);
}
- (void)captureOutput:(AVCaptureOutput *)output
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {
    if (!sampleBuffer) return;
    CVImageBufferRef img = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (img) {
        _lastWidth = (uint32_t)CVPixelBufferGetWidth(img);
        _lastHeight = (uint32_t)CVPixelBufferGetHeight(img);
        _lastHadIOSurface = (CVPixelBufferGetIOSurface(img) != NULL);
    }
    CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    if (CMTIME_IS_VALID(_lastPTS) && CMTimeCompare(pts, _lastPTS) <= 0) {
        _ptsViolations++;
    }
    _lastPTS = pts;
    atomic_fetch_add_explicit(&_frameCount, 1, memory_order_relaxed);
}
@end

@interface MockBaseCaptureOutput : NSObject
@property (nonatomic, strong) id receivedDelegate;
@property (nonatomic, assign) int callCount;
- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)sampleBufferDelegate
                          queue:(dispatch_queue_t)sampleBufferCallbackQueue;
@end

@implementation MockBaseCaptureOutput
- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)sampleBufferDelegate
                          queue:(dispatch_queue_t)sampleBufferCallbackQueue {
    _receivedDelegate = sampleBufferDelegate;
    _callCount++;
}
@end

@interface MockTundraCaptureOutput : NSObject
@property (nonatomic, strong) id receivedDelegate;
@property (nonatomic, assign) int callCount;
- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)sampleBufferDelegate
                          queue:(dispatch_queue_t)sampleBufferCallbackQueue;
@end

@implementation MockTundraCaptureOutput
- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)sampleBufferDelegate
                          queue:(dispatch_queue_t)sampleBufferCallbackQueue {
    _receivedDelegate = sampleBufferDelegate;
    _callCount++;
}
@end

@interface MockSampleDelegate : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@property (nonatomic, assign) int frameCount;
@end

@implementation MockSampleDelegate
- (void)captureOutput:(AVCaptureOutput *)output
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {
    if (sampleBuffer) {
        _frameCount++;
    }
}
@end

typedef struct {
    uint32_t magic;
    uint32_t version;
    uint32_t width;
    uint32_t height;
    uint32_t stride;
    uint32_t format;
    _Atomic uint64_t seq;
    uint64_t ts_ns;
    uint32_t slots;
    uint32_t slot_bytes;
    uint8_t reserved[16];
} TestRingHeader;

static uint64_t now_ns(void) {
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    return (uint64_t)(((__uint128_t)mach_continuous_time() * tb.numer) / tb.denom);
}

static CMSampleBufferRef create_dummy_sample(uint32_t w, uint32_t h, uint8_t yVal) {
    CVPixelBufferRef pb = NULL;
    NSDictionary *attrs = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        (id)kCVPixelBufferWidthKey: @(w),
        (id)kCVPixelBufferHeightKey: @(h),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{}
    };
    assert(CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, (__bridge CFDictionaryRef)attrs, &pb) == kCVReturnSuccess);
    CVPixelBufferLockBaseAddress(pb, 0);
    memset(CVPixelBufferGetBaseAddressOfPlane(pb, 0), yVal, CVPixelBufferGetBytesPerRowOfPlane(pb, 0) * h);
    memset(CVPixelBufferGetBaseAddressOfPlane(pb, 1), 0x80, CVPixelBufferGetBytesPerRowOfPlane(pb, 1) * (h / 2));
    CVPixelBufferUnlockBaseAddress(pb, 0);

    CMVideoFormatDescriptionRef fmt = NULL;
    assert(CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pb, &fmt) == noErr);
    CMSampleTimingInfo timing = {
        .duration = CMTimeMake(1, 30),
        .presentationTimeStamp = CMTimeMake(100, 30),
        .decodeTimeStamp = kCMTimeInvalid
    };
    CMSampleBufferRef sb = NULL;
    assert(CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, pb, fmt, &timing, &sb) == noErr);
    CFRelease(fmt);
    CFRelease(pb);
    return sb;
}

int main(void) {
    const char *path = "/tmp/bb-camera-test.ring";
    unlink(path);

    uint32_t w = 320, h = 240, stride = 320, slots = 3;
    uint32_t slotBytes = stride * h * 3 / 2;
    size_t totalSize = sizeof(TestRingHeader) + (size_t)slots * slotBytes;

    int fd = open(path, O_CREAT | O_RDWR | O_TRUNC, 0644);
    assert(fd >= 0);
    assert(fchmod(fd, 0644) == 0);
    assert(ftruncate(fd, (off_t)totalSize) == 0);
    void *map = mmap(NULL, totalSize, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    assert(map != MAP_FAILED);

    TestRingHeader *hdr = (TestRingHeader *)map;
    memset(hdr, 0, totalSize);
    hdr->magic = 0x42424352u;
    hdr->version = 1;
    hdr->width = w;
    hdr->height = h;
    hdr->stride = stride;
    hdr->format = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    hdr->slots = slots;
    hdr->slot_bytes = slotBytes;

    CMSampleBufferRef orig = create_dummy_sample(640, 480, 0x10);

    // 1. seq == 0 -> fallback (NULL)
    assert(BBCameraHookCreateSwappedSampleBuffer(orig, path) == NULL);

    // 2. Write fresh frame into slot 0 (seq 0 -> 1 -> 2) with Y=0xC8
    atomic_fetch_add_explicit(&hdr->seq, 1, memory_order_acq_rel);
    uint8_t *slot0 = (uint8_t *)map + sizeof(TestRingHeader);
    memset(slot0, 0xC8, stride * h);
    memset(slot0 + stride * h, 0x80, stride * (h / 2));
    hdr->ts_ns = now_ns();
    atomic_fetch_add_explicit(&hdr->seq, 1, memory_order_acq_rel);

    CMSampleBufferRef swapped = BBCameraHookCreateSwappedSampleBuffer(orig, path);
    assert(swapped != NULL);
    CVImageBufferRef img = CMSampleBufferGetImageBuffer(swapped);
    assert(CVPixelBufferGetWidth(img) == 640);
    assert(CVPixelBufferGetHeight(img) == 480);
    CVPixelBufferLockBaseAddress(img, kCVPixelBufferLock_ReadOnly);
    uint8_t ySample = *((uint8_t *)CVPixelBufferGetBaseAddressOfPlane(img, 0));
    CVPixelBufferUnlockBaseAddress(img, kCVPixelBufferLock_ReadOnly);
    // VTPixelTransfer scales 0xC8 (200) -> ~200
    assert(ySample >= 190 && ySample <= 210);
    CFRelease(swapped);

    // 3. Stale timestamp (>500ms ago) -> fallback (NULL)
    hdr->ts_ns = now_ns() - 600000000ULL;
    assert(BBCameraHookCreateSwappedSampleBuffer(orig, path) == NULL);

    // 4. Disabled (ts_ns = 0) -> fallback (NULL) & releases GPU resources while keeping ring mapped
    hdr->ts_ns = 0;
    assert(BBCameraHookCreateSwappedSampleBuffer(orig, path) == NULL);
    // Immediate re-enable without waiting 200ms open throttle proves ring stayed mapped
    hdr->ts_ns = now_ns();
    CMSampleBufferRef resumed = BBCameraHookCreateSwappedSampleBuffer(orig, path);
    assert(resumed != NULL);
    CFRelease(resumed);

    // 5. Odd seq (writer in progress) -> fallback (NULL)
    hdr->ts_ns = now_ns();
    atomic_fetch_add_explicit(&hdr->seq, 1, memory_order_acq_rel);
    assert(BBCameraHookCreateSwappedSampleBuffer(orig, path) == NULL);

    // 6. Odd width -> fallback (NULL)
    atomic_fetch_add_explicit(&hdr->seq, 1, memory_order_acq_rel);
    hdr->width = 321;
    assert(BBCameraHookCreateSwappedSampleBuffer(orig, path) == NULL);
    hdr->width = w;

    // 7. Group/world-writable ring -> rejected (NULL) after 200ms lstat throttle
    usleep(220000);
    assert(fchmod(fd, 0666) == 0);
    assert(BBCameraHookCreateSwappedSampleBuffer(orig, path) == NULL);
    assert(fchmod(fd, 0644) == 0);

    // 8. Symlink ring -> rejected (NULL) after 200ms open throttle
    usleep(220000);
    const char *linkPath = "/tmp/bb-camera-test.link";
    unlink(linkPath);
    assert(symlink(path, linkPath) == 0);
    assert(BBCameraHookCreateSwappedSampleBuffer(orig, linkPath) == NULL);
    unlink(linkPath);

    // 9. Restored 0644 regular ring -> re-maps cleanly after 200ms throttle
    usleep(220000);
    hdr->ts_ns = now_ns();
    CMSampleBufferRef remapped = BBCameraHookCreateSwappedSampleBuffer(orig, path);
    assert(remapped != NULL);
    CFRelease(remapped);

    // 10. Concurrent frame swap + GPU resource teardown (ts_ns = 0) must not race/crash
    dispatch_group_t grp = dispatch_group_create();
    dispatch_queue_t q1 = dispatch_queue_create("bb.test.swap", DISPATCH_QUEUE_CONCURRENT);
    for (int i = 0; i < 40; i++) {
        dispatch_group_async(grp, q1, ^{
            hdr->ts_ns = (i % 3 == 0) ? 0 : now_ns();
            CMSampleBufferRef sb = BBCameraHookCreateSwappedSampleBuffer(orig, path);
            if (sb) CFRelease(sb);
        });
    }
    dispatch_group_wait(grp, DISPATCH_TIME_FOREVER);

    CFRelease(orig);
    munmap(map, totalSize);
    close(fd);
    unlink(path);

    // 11. 1920x1080 landscape, 1080x1920 portrait (letterboxed), and >1920*1080 rejection
    usleep(220000);
    const char *path1080 = "/tmp/bb-camera-test-1080p.ring";
    unlink(path1080);
    uint32_t maxSlot1080 = 1920u * 1080u * 3u / 2u;
    size_t total1080 = sizeof(TestRingHeader) + (size_t)slots * maxSlot1080;
    int fd2 = open(path1080, O_CREAT | O_RDWR | O_TRUNC, 0644);
    assert(fd2 >= 0);
    assert(fchmod(fd2, 0644) == 0);
    assert(ftruncate(fd2, (off_t)total1080) == 0);
    void *map2 = mmap(NULL, total1080, PROT_READ | PROT_WRITE, MAP_SHARED, fd2, 0);
    assert(map2 != MAP_FAILED);

    TestRingHeader *hdr2 = (TestRingHeader *)map2;
    memset(hdr2, 0, total1080);
    hdr2->magic = 0x42424352u;
    hdr2->version = 1;
    hdr2->format = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    hdr2->slots = slots;
    hdr2->slot_bytes = maxSlot1080;

    CMSampleBufferRef origLandscape = create_dummy_sample(1280, 720, 0x10);
    uint8_t *slot1080 = (uint8_t *)map2 + sizeof(TestRingHeader);
    memset(slot1080, 0xC8, 1920u * 1080u);
    memset(slot1080 + 1920u * 1080u, 0x80, 1920u * 540u);

    // 11a. 1920x1080 landscape
    hdr2->width = 1920;
    hdr2->height = 1080;
    hdr2->stride = 1920;
    hdr2->ts_ns = now_ns();
    atomic_store_explicit(&hdr2->seq, 2, memory_order_release);
    CMSampleBufferRef swapped1080 = BBCameraHookCreateSwappedSampleBuffer(origLandscape, path1080);
    assert(swapped1080 != NULL);
    CFRelease(swapped1080);

    // 11b. 1080x1920 portrait letterboxed into 1280x720 landscape (slot 1 for seq=4; left edge pillarbox is dark, center is ~0xC8)
    uint8_t *slot1_1080 = (uint8_t *)map2 + sizeof(TestRingHeader) + maxSlot1080;
    memset(slot1_1080, 0xC8, 1920u * 1080u);
    memset(slot1_1080 + 1920u * 1080u, 0x80, 1920u * 540u);
    hdr2->width = 1080;
    hdr2->height = 1920;
    hdr2->stride = 1080;
    hdr2->ts_ns = now_ns();
    atomic_store_explicit(&hdr2->seq, 4, memory_order_release);
    CMSampleBufferRef swappedPort = BBCameraHookCreateSwappedSampleBuffer(origLandscape, path1080);
    assert(swappedPort != NULL);
    CVImageBufferRef portImg = CMSampleBufferGetImageBuffer(swappedPort);
    CVPixelBufferLockBaseAddress(portImg, kCVPixelBufferLock_ReadOnly);
    uint8_t *portY = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(portImg, 0);
    size_t portStride = CVPixelBufferGetBytesPerRowOfPlane(portImg, 0);
    uint8_t leftEdgeY = portY[360 * portStride + 4];
    uint8_t centerY = portY[360 * portStride + 640];
    CVPixelBufferUnlockBaseAddress(portImg, kCVPixelBufferLock_ReadOnly);
    assert(leftEdgeY < 40);
    assert(centerY >= 190 && centerY <= 210);
    CFRelease(swappedPort);

    // 11c. > 1920*1080 rejected (e.g. 1920x1082)
    hdr2->width = 1920;
    hdr2->height = 1082;
    hdr2->stride = 1920;
    hdr2->ts_ns = now_ns();
    atomic_store_explicit(&hdr2->seq, 6, memory_order_release);
    assert(BBCameraHookCreateSwappedSampleBuffer(origLandscape, path1080) == NULL);

    CFRelease(origLandscape);
    munmap(map2, total1080);
    close(fd2);
    unlink(path1080);

    // 12. Dual-class swizzle (base + sibling Tundra class) routes each to its own original IMP with BBProxyDelegate
    assert(BBCameraHookInstallOnClasses([MockBaseCaptureOutput class], [MockTundraCaptureOutput class]) == YES);
    MockBaseCaptureOutput *mockBase = [[MockBaseCaptureOutput alloc] init];
    MockTundraCaptureOutput *mockTundra = [[MockTundraCaptureOutput alloc] init];
    MockSampleDelegate *rawDelegate = [[MockSampleDelegate alloc] init];

    [mockBase setSampleBufferDelegate:rawDelegate queue:dispatch_get_main_queue()];
    [mockTundra setSampleBufferDelegate:rawDelegate queue:dispatch_get_main_queue()];

    assert(mockBase.callCount == 1);
    assert(mockTundra.callCount == 1);
    assert(mockBase.receivedDelegate != nil && mockBase.receivedDelegate != rawDelegate);
    assert(mockTundra.receivedDelegate != nil && mockTundra.receivedDelegate != rawDelegate);
    assert(strcmp(class_getName(object_getClass(mockBase.receivedDelegate)), "BBProxyDelegate") == 0);
    assert(strcmp(class_getName(object_getClass(mockTundra.receivedDelegate)), "BBProxyDelegate") == 0);

    CMSampleBufferRef testFrame = create_dummy_sample(640, 480, 0x40);
    [mockTundra.receivedDelegate captureOutput:(AVCaptureOutput *)mockTundra
                         didOutputSampleBuffer:testFrame
                                fromConnection:(id)nil];
    assert(rawDelegate.frameCount == 1);
    CFRelease(testFrame);

    [mockBase setSampleBufferDelegate:nil queue:nil];
    [mockTundra setSampleBufferDelegate:nil queue:nil];
    assert(mockBase.callCount == 2 && mockBase.receivedDelegate == nil);
    assert(mockTundra.callCount == 2 && mockTundra.receivedDelegate == nil);

    // 13. Clamshell synthetic fallback pump tests (a, b, c, d)
    usleep(220000);
    const char *pumpRingPath = "/tmp/bb-camera-test-pump.ring";
    unlink(pumpRingPath);
    int fdPump = open(pumpRingPath, O_CREAT | O_RDWR | O_TRUNC, 0644);
    assert(fdPump >= 0);
    assert(fchmod(fdPump, 0644) == 0);
    assert(ftruncate(fdPump, (off_t)totalSize) == 0);
    void *mapPump = mmap(NULL, totalSize, PROT_READ | PROT_WRITE, MAP_SHARED, fdPump, 0);
    assert(mapPump != MAP_FAILED);

    TestRingHeader *hdrPump = (TestRingHeader *)mapPump;
    memset(hdrPump, 0, totalSize);
    hdrPump->magic = 0x42424352u;
    hdrPump->version = 1;
    hdrPump->width = w;
    hdrPump->height = h;
    hdrPump->stride = stride;
    hdrPump->format = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    hdrPump->slots = slots;
    hdrPump->slot_bytes = slotBytes;
    uint8_t *slotPump = (uint8_t *)mapPump + sizeof(TestRingHeader);
    memset(slotPump, 0xB0, stride * h);
    memset(slotPump + stride * h, 0x80, stride * (h / 2));
    hdrPump->ts_ns = now_ns();
    atomic_store_explicit(&hdrPump->seq, 2, memory_order_release);

    BBCameraHookSetRingPathForTesting(pumpRingPath);
    assert(BBCameraHookInstallOnClasses([MockPumpCaptureOutput class], nil) == YES);

    MockPumpSession *pumpSession = [[MockPumpSession alloc] init];
    pumpSession.running = YES;
    MockPumpPort *pumpPort = [[MockPumpPort alloc] init];
    pumpPort.clock = CMClockGetHostTimeClock();
    MockPumpConnection *pumpConn = [[MockPumpConnection alloc] init];
    pumpConn.enabled = YES;
    pumpConn.active = YES;
    pumpConn.inputPorts = @[pumpPort];

    MockPumpCaptureOutput *mockPumpOut = [[MockPumpCaptureOutput alloc] init];
    mockPumpOut.session = pumpSession;
    mockPumpOut.videoConnection = pumpConn;
    mockPumpOut.videoSettings = @{
        (id)kCVPixelBufferWidthKey: @640,
        (id)kCVPixelBufferHeightKey: @480,
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    };

    MockPumpDelegate *pumpDel = [[MockPumpDelegate alloc] init];
    dispatch_queue_t pumpQueue = dispatch_queue_create("bb.test.pump", DISPATCH_QUEUE_SERIAL);

    // 13a. Synthetic pump fires on queue when ring is fresh and no real frames arrive
    [mockPumpOut setSampleBufferDelegate:pumpDel queue:pumpQueue];
    usleep(200000);
    dispatch_sync(pumpQueue, ^{});
    int count13a = [pumpDel currentFrameCount];
    assert(count13a >= 2);
    assert(pumpDel.lastWidth == 640 && pumpDel.lastHeight == 480);
    assert(pumpDel.lastHadIOSurface == YES);
    assert(pumpDel.ptsViolations == 0);

    // 13a-array. videoSettings with NSArray pixel-format value must not throw and must still deliver frames
    mockPumpOut.videoSettings = @{(id)kCVPixelBufferPixelFormatTypeKey: @[@(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)]};
    int beforeArrayFmt = [pumpDel currentFrameCount];
    usleep(120000);
    dispatch_sync(pumpQueue, ^{});
    assert([pumpDel currentFrameCount] > beforeArrayFmt);

    // 13b. Pump suppresses itself while real frames are arriving and resumes after >=250ms gap
    CMSampleBufferRef realSample = create_dummy_sample(640, 480, 0x50);
    int baselineBeforeReal = [pumpDel currentFrameCount];
    int realSent = 5;
    for (int i = 0; i < realSent; i++) {
        hdrPump->ts_ns = now_ns();
        dispatch_sync(pumpQueue, ^{
            [mockPumpOut.receivedDelegate captureOutput:(AVCaptureOutput *)mockPumpOut
                                   didOutputSampleBuffer:realSample
                                          fromConnection:(AVCaptureConnection *)pumpConn];
        });
        usleep(50000);
    }
    CFRelease(realSample);
    dispatch_sync(pumpQueue, ^{});
    int countAfterReal = [pumpDel currentFrameCount];
    assert(countAfterReal == baselineBeforeReal + realSent);

    // Wait >250ms for pump to resume
    hdrPump->ts_ns = now_ns();
    usleep(420000);
    dispatch_sync(pumpQueue, ^{});
    int countAfterResume = [pumpDel currentFrameCount];
    assert(countAfterResume > countAfterReal);

    // 13c. Pump does NOT fire when session.isRunning == NO or ring is stale
    pumpSession.running = NO;
    dispatch_sync(pumpQueue, ^{});
    int countStoppedSession = [pumpDel currentFrameCount];
    usleep(150000);
    dispatch_sync(pumpQueue, ^{});
    assert([pumpDel currentFrameCount] == countStoppedSession);

    pumpSession.running = YES;
    hdrPump->ts_ns = now_ns() - 600000000ULL;
    dispatch_sync(pumpQueue, ^{});
    int countStaleRing = [pumpDel currentFrameCount];
    usleep(150000);
    dispatch_sync(pumpQueue, ^{});
    assert([pumpDel currentFrameCount] == countStaleRing);

    // 13d. Pump stops cleanly on setSampleBufferDelegate:nil queue:nil
    hdrPump->ts_ns = now_ns();
    [mockPumpOut setSampleBufferDelegate:nil queue:nil];
    dispatch_sync(pumpQueue, ^{});
    int countAfterNil = [pumpDel currentFrameCount];
    usleep(150000);
    dispatch_sync(pumpQueue, ^{});
    assert([pumpDel currentFrameCount] == countAfterNil);
    assert(mockPumpOut.receivedDelegate == nil);

    BBCameraHookSetRingPathForTesting(NULL);
    munmap(mapPump, totalSize);
    close(fdPump);
    unlink(pumpRingPath);

    // 14. isSuspended returns NO when bb-camera.active exists and delegates otherwise
    char flagPath[] = "/tmp/bb_camera_active_test_XXXXXX";
    int flagFd = mkstemp(flagPath);
    assert(flagFd >= 0);
    close(flagFd);
    unlink(flagPath);

    BBCameraHookSetActiveFlagPathForTesting(flagPath);
    assert(BBCameraHookInstallSuspendedOnClasses([MockSuspendedDevice class], Nil, Nil) == YES);
    MockSuspendedDevice *mockDev = [[MockSuspendedDevice alloc] init];
    mockDev.rawSuspended = YES;
    assert([mockDev isSuspended] == YES);

    int activeFd = open(flagPath, O_CREAT | O_WRONLY, 0644);
    assert(activeFd >= 0);
    close(activeFd);
    assert([mockDev isSuspended] == NO);

    unlink(flagPath);
    assert([mockDev isSuspended] == YES);
    BBCameraHookSetActiveFlagPathForTesting(NULL);

    // 15. Downlink ring writer captures CVPixelBuffer into bb-downlink.ring
    extern void BBCameraHookSetDownlinkRingPathForTesting(const char *path);
    extern BOOL BBCameraHookWriteDownlinkPixelBuffer(CVPixelBufferRef frame);
    extern BOOL BBCameraHookWriteDownlinkPixelBufferWithOrientation(CVPixelBufferRef frame, uint32_t orientation, BOOL hasOrientation);
    const char *dlRingPath = "/tmp/bb-downlink-test.ring";
    unlink(dlRingPath);
    BBCameraHookSetDownlinkRingPathForTesting(dlRingPath);
    CMSampleBufferRef dlSample = create_dummy_sample(320, 240, 0x5A);
    CVPixelBufferRef dlPb = CMSampleBufferGetImageBuffer(dlSample);
    assert(dlPb != NULL);
    assert(BBCameraHookWriteDownlinkPixelBuffer(dlPb) == YES);
    assert(BBCameraHookWriteDownlinkPixelBufferWithOrientation(dlPb, 2, YES) == YES);
    CFRelease(dlSample);

    int dlFd = open(dlRingPath, O_RDONLY);
    assert(dlFd >= 0);
    struct stat dlSt;
    assert(fstat(dlFd, &dlSt) == 0 && (size_t)dlSt.st_size >= sizeof(TestRingHeader) + 320 * 240);
    void *dlMap = mmap(NULL, (size_t)dlSt.st_size, PROT_READ, MAP_SHARED, dlFd, 0);
    assert(dlMap != MAP_FAILED);
    TestRingHeader *dlHdr = (TestRingHeader *)dlMap;
    assert(dlHdr->magic == 0x42424352u);
    assert(dlHdr->width == 320);
    assert(dlHdr->height == 240);
    assert(atomic_load_explicit(&dlHdr->seq, memory_order_acquire) == 2);
    uint32_t dlOri = 0, dlFlags = 0;
    memcpy(&dlOri, dlHdr->reserved, 4);
    memcpy(&dlFlags, dlHdr->reserved + 4, 4);
    assert(dlOri == 2 && dlFlags == 1);
    uint8_t *dlSlot2 = (uint8_t *)dlMap + sizeof(TestRingHeader) + (size_t)(2 % dlHdr->slots) * dlHdr->slot_bytes;
    assert(dlSlot2[0] == 0x5A);
    munmap(dlMap, (size_t)dlSt.st_size);
    close(dlFd);
    unlink(dlRingPath);
    BBCameraHookSetDownlinkRingPathForTesting(NULL);

    // 16. VPIO bypass predicate returns NO for NULL and non-VPIO AudioUnits
    extern BOOL BBCameraHookShouldBypassVPIO(AudioUnit unit);
    assert(BBCameraHookShouldBypassVPIO(NULL) == NO);

    char vpioFlagPath[] = "/tmp/bb_vpio_active_test_XXXXXX";
    int vpioFlagFd = mkstemp(vpioFlagPath);
    assert(vpioFlagFd >= 0);
    close(vpioFlagFd);
    unlink(vpioFlagPath);
    BBCameraHookSetActiveFlagPathForTesting(vpioFlagPath);

    AudioComponentDescription genDesc = {
        .componentType = kAudioUnitType_Output,
        .componentSubType = kAudioUnitSubType_GenericOutput,
        .componentManufacturer = kAudioUnitManufacturer_Apple,
    };
    AudioComponent genComp = AudioComponentFindNext(NULL, &genDesc);
    if (genComp) {
        AudioUnit genUnit = NULL;
        assert(AudioComponentInstanceNew(genComp, &genUnit) == noErr && genUnit != NULL);
        int fdActive = open(vpioFlagPath, O_CREAT | O_WRONLY, 0644);
        assert(fdActive >= 0);
        close(fdActive);
        assert(BBCameraHookShouldBypassVPIO(genUnit) == NO);
        unlink(vpioFlagPath);
        AudioComponentInstanceDispose(genUnit);
    }
    BBCameraHookSetActiveFlagPathForTesting(NULL);

    printf("BlueBubblesCameraHookTests: ALL PASSED\n");
    return 0;
}
