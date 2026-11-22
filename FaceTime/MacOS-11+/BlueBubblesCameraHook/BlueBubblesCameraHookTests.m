#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
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
    printf("BlueBubblesCameraHookTests: ALL PASSED\n");
    return 0;
}
